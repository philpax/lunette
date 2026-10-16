-- Packs a panel's recorded primitives into box instance data and text runs for one frame. Positions come from this
-- frame's layout and animation, so a hover lift or a scroll needs no visual to run again.

local uiHost = require '@lunette-contracts/ui-host'
local records = require '../records'
local record = require './record'
local shader = require './shader'

local pack = {}

-- Successive primitives of one node step towards the viewer, so coplanar fills and borders do not depth-fight.
local PRIMITIVE_STEP = 0.00005
local UNCLIPPED = table.freeze { -1e6, -1e6, 1e6, 1e6 }

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

export type Packed = {
  boxes: { number },
  count: number,
  texts: { TextRun },
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
  local packed: Packed = into or { boxes = {}, count = 0, texts = {} }
  local boxes = packed.boxes
  local count = 0
  table.clear(packed.texts)
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
          if primitive.edges then edgeWidth else 0, 0, 0, 0
        count += 1
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

return pack
