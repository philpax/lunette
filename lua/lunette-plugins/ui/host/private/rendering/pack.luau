-- Packs a panel's recorded primitives into box instance data and text runs for one frame. Positions come from this
-- frame's layout and animation, so a hover lift or a scroll needs no visual to run again.

local uiHost = require '@lunette-contracts/ui-host'
local records = require '../records'
local record = require './record'
local shader = require './shader'

local pack = {}

-- Successive primitives of one node step towards the viewer, so coplanar fills and borders do not depth-fight.
local PRIMITIVE_STEP = 0.00001
local UNCLIPPED = table.freeze { -1e6, -1e6, 1e6, 1e6 }
local TRANSPARENT = table.freeze { 0, 0, 0, 0 }

export type TextRun = {
  text: string,
  family: string,
  weight: number,
  size: number,
  x: number,
  baseline: number,
  width: number,
  z: number,
  color: uiHost.Color,
  clip: { number },
}

export type ImageRun = {
  source: uiHost.ImageSource,
  x: number,
  y: number,
  width: number,
  height: number,
  z: number,
  tint: uiHost.Color,
  clip: { number },
}

export type Packed = {
  boxes: { number },
  count: number,
  texts: { TextRun },
  images: { ImageRun },
}

local function intersect(clip: { number }, node: records.Node): { number }
  return {
    math.max(clip[1], node.x),
    math.max(clip[2], node.y),
    math.min(clip[3], node.x + node.width),
    math.min(clip[4], node.y + node.height),
  }
end

local function color(target: { number }, at: number, value: uiHost.Color): ()
  target[at], target[at + 1], target[at + 2], target[at + 3] = value[1], value[2], value[3], value[4] or 1
end

local function lineText(source: string, line: any): string
  local glyphs = line.glyphs
  if #glyphs == 0 then
    return ''
  end
  local first, last = math.huge, 0
  for _, glyph in glyphs do
    first = math.min(first, glyph.byteStart)
    last = math.max(last, glyph.byteEnd)
  end
  return string.sub(source, first, last)
end

-- Records stale visuals and packs every visible primitive in tree order.
function pack.run(panel: records.Panel, env: records.Environment, visuals: record.Visuals, into: Packed?): Packed
  local packed: Packed = into or { boxes = {}, count = 0, texts = {}, images = {} }
  local boxes = packed.boxes
  local count = 0
  table.clear(packed.texts)
  table.clear(packed.images)
  local tokens = env.theme()
  local contentOffset = tokens.elevation.contentOffset
  local edgeWidth = tokens.sizes.edge
  local function visit(node: records.Node, clip: { number }): ()
    local primitives = node.primitives or record.run(node, env, visuals)
    node.primitives = primitives
    local parentSurface = node.z - node.elevation - node.lift
    for index, primitive in primitives do
      local step = (index - 1) * PRIMITIVE_STEP
      if primitive.kind == 'box' then
        local top = node.z + primitive.offset + step
        local depth = if primitive.side then primitive.depth or math.max(top - parentSurface, 0) else 0
        local at = count * shader.SLOTS * 4
        boxes[at + 1], boxes[at + 2] = node.x + primitive.x, node.y + primitive.y
        boxes[at + 3], boxes[at + 4] = primitive.width, primitive.height
        boxes[at + 5], boxes[at + 6], boxes[at + 7], boxes[at + 8] = top, depth, primitive.radius, primitive.border
        color(boxes, at + 9, primitive.fill)
        color(boxes, at + 13, primitive.borderColor)
        color(boxes, at + 17, primitive.side or primitive.fill)
        boxes[at + 21], boxes[at + 22], boxes[at + 23], boxes[at + 24] = clip[1], clip[2], clip[3], clip[4]
        boxes[at + 25], boxes[at + 26], boxes[at + 27], boxes[at + 28] =
          if primitive.edges then edgeWidth else 0, primitive.rotation, 0, 0
        count += 1
      elseif primitive.kind == 'image' then
        packed.images[#packed.images + 1] = {
          source = primitive.source,
          x = node.x + primitive.x,
          y = node.y + primitive.y,
          width = primitive.width,
          height = primitive.height,
          z = node.z + contentOffset + primitive.offset + step,
          tint = primitive.tint,
          clip = clip,
        }
      else
        for _, line in primitive.lines do
          local text = lineText(primitive.source, line)
          if text ~= '' then
            local first, last = assert(line.glyphs[1]), assert(line.glyphs[#line.glyphs])
            packed.texts[#packed.texts + 1] = {
              text = text,
              family = primitive.family,
              weight = primitive.weight,
              size = first.size,
              x = node.x + primitive.x + first.x,
              baseline = node.y + primitive.y + line.baseline,
              width = last.x + last.advance - first.x,
              z = node.z + contentOffset + primitive.offset + step,
              color = primitive.color,
              clip = clip,
            }
          end
        end
      end
    end
    -- A node focused by traversal shows a ring in the accent colour just outside its box. Focus from a pointer press
    -- shows none, in the manner of the web's focus-visible.
    if node.host.focusVisible then
      local margin = tokens.sizes.headerRule * 1.5
      local ring = tokens.sizes.headerRule
      local at = count * shader.SLOTS * 4
      boxes[at + 1], boxes[at + 2] = node.x - margin, node.y - margin
      boxes[at + 3], boxes[at + 4] = node.width + margin * 2, node.height + margin * 2
      boxes[at + 5], boxes[at + 6] = node.z + contentOffset * 2 + #primitives * PRIMITIVE_STEP, 0
      boxes[at + 7], boxes[at + 8] = tokens.radii.control + margin, ring
      color(boxes, at + 9, TRANSPARENT)
      color(boxes, at + 13, tokens.colors.accent)
      color(boxes, at + 17, TRANSPARENT)
      boxes[at + 21], boxes[at + 22], boxes[at + 23], boxes[at + 24] = clip[1], clip[2], clip[3], clip[4]
      boxes[at + 25], boxes[at + 26], boxes[at + 27], boxes[at + 28] = 0, 0, 0, 0
      count += 1
    end
    local childClip = if node.kind.registration.clip then intersect(clip, node) else clip
    for _, child in node.children do
      visit(child, childClip)
    end
  end
  if panel.root then
    visit(panel.root, UNCLIPPED)
  end
  -- Entries past this frame's count are left in place and not drawn.
  packed.count = count
  return packed
end

-- The fingertip proxy is held at the surface it touches until the fingertip is this far through.
local UNCLAMP_DEPTH = 0.02

-- Adds a fingertip proxy: a disc on the surface beneath the fingertip, which grows as the fingertip approaches and
-- takes the accent colour in contact.
function pack.marker(packed: Packed, x: number, y: number, surface: number, depth: number, theme: uiHost.Theme): ()
  if depth < -UNCLAMP_DEPTH then
    return
  end
  local contact = depth <= 0
  local size = if contact then 0.006 else 0.004 + math.clamp(1 - depth / 0.03, 0, 1) * 0.002
  local color = if contact then theme.colors.accent else theme.colors.ink
  local top = surface + math.max(depth, 0) + theme.elevation.contentOffset * 2
  local at = packed.count * shader.SLOTS * 4
  local boxes = packed.boxes
  boxes[at + 1], boxes[at + 2], boxes[at + 3], boxes[at + 4] = x - size / 2, y - size / 2, size, size
  boxes[at + 5], boxes[at + 6], boxes[at + 7], boxes[at + 8] = top, 0, size / 2, size * 0.18
  boxes[at + 9], boxes[at + 10], boxes[at + 11], boxes[at + 12] = color[1], color[2], color[3], 0.35
  boxes[at + 13], boxes[at + 14], boxes[at + 15], boxes[at + 16] = color[1], color[2], color[3], 1
  boxes[at + 17], boxes[at + 18], boxes[at + 19], boxes[at + 20] = color[1], color[2], color[3], 1
  boxes[at + 21], boxes[at + 22], boxes[at + 23], boxes[at + 24] =
    UNCLIPPED[1], UNCLIPPED[2], UNCLIPPED[3], UNCLIPPED[4]
  boxes[at + 25], boxes[at + 26], boxes[at + 27], boxes[at + 28] = 0, 0, 0, 0
  packed.count += 1
end

return pack
