-- Packs a panel's recorded primitives into box and glyph instance data for one frame. Positions come from this
-- frame's layout and animation, so a hover lift or a scroll needs no visual to run again.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local records = require '../records'
local record = require './record'
local shader = require './shader'

local pack = {}

-- Successive primitives of one node step towards the viewer, so coplanar fills and borders do not depth-fight.
local PRIMITIVE_STEP = 0.00001
local UNCLIPPED = table.freeze { -1e6, -1e6, 1e6, 1e6 }
local TRANSPARENT = table.freeze { 0, 0, 0, 0 }

-- A glyph's place in the atlas, as `GlyphAtlas:glyph` answers it, or nil for a glyph that draws nothing.
export type Glyph = lunette.GlyphPlacement
export type Glyphs = (face: number, id: number) -> Glyph?

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
  -- Glyph instance data per atlas page, and the number of glyphs on each.
  glyphs: { [number]: { number } },
  glyphCounts: { [number]: number },
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

-- Whether a node lies wholly outside a clip, such as a row scrolled out of view. Its content lies within it, so its
-- subtree draws nothing and is neither recorded nor packed.
local function outside(clip: { number }, node: records.Node): boolean
  return node.x >= clip[3] or node.y >= clip[4] or node.x + node.width <= clip[1] or node.y + node.height <= clip[2]
end

local function color(target: { number }, at: number, value: uiHost.Color): ()
  target[at], target[at + 1], target[at + 2], target[at + 3] = value[1], value[2], value[3], value[4] or 1
end

-- Records stale visuals and packs every visible primitive in tree order.
-- Where a run of primitives is drawn, and how opaque.
type Placement = {
  x: number,
  y: number,
  z: number,
  parentSurface: number,
  clip: { number },
  opacity: number,
}

local function faded(value: uiHost.Color, opacity: number): uiHost.Color
  if opacity >= 1 then
    return value
  end
  return { value[1], value[2], value[3], (value[4] or 1) * opacity }
end

-- Records stale visuals and packs every visible primitive in tree order, then the ghosts of exiting nodes.
function pack.run(
  panel: records.Panel,
  env: records.Environment,
  visuals: record.Visuals,
  glyphs: Glyphs,
  into: Packed?
): Packed
  local packed: Packed = into or { boxes = {}, count = 0, glyphs = {}, glyphCounts = {}, images = {} }
  local boxes = packed.boxes
  local count = 0
  table.clear(packed.glyphCounts)
  table.clear(packed.images)
  local function glyph(
    placement: Glyph,
    x: number,
    baseline: number,
    size: number,
    z: number,
    tint: uiHost.Color,
    clip: { number }
  ): ()
    local page = placement.page
    local data = packed.glyphs[page]
    if not data then
      data = {}
      packed.glyphs[page] = data
    end
    local index = packed.glyphCounts[page] or 0
    packed.glyphCounts[page] = index + 1
    local slot = index * shader.GLYPH_SLOTS * 4
    data[slot + 1], data[slot + 2] = x + placement.left * size, baseline - placement.top * size
    data[slot + 3], data[slot + 4] = placement.width * size, placement.height * size
    data[slot + 5], data[slot + 6], data[slot + 7], data[slot + 8] =
      placement.u0, placement.v0, placement.u1, placement.v1
    color(data, slot + 9, tint)
    data[slot + 13], data[slot + 14], data[slot + 15], data[slot + 16] = clip[1], clip[2], clip[3], clip[4]
    data[slot + 17], data[slot + 18], data[slot + 19], data[slot + 20] = z, 0, 0, 0
  end
  local tokens = env.theme()
  local contentOffset = tokens.elevation.contentOffset
  local edgeWidth = tokens.sizes.edge
  local function emit(primitives: { records.Primitive }, at: Placement): ()
    local opacity = at.opacity
    for index, primitive in primitives do
      local step = (index - 1) * PRIMITIVE_STEP
      if primitive.kind == 'box' then
        local top = at.z + primitive.offset + step
        local depth = if primitive.side then primitive.depth or math.max(top - at.parentSurface, 0) else 0
        local slot = count * shader.SLOTS * 4
        boxes[slot + 1], boxes[slot + 2] = at.x + primitive.x, at.y + primitive.y
        boxes[slot + 3], boxes[slot + 4] = primitive.width, primitive.height
        boxes[slot + 5], boxes[slot + 6], boxes[slot + 7], boxes[slot + 8] =
          top, depth, primitive.radius, primitive.border
        color(boxes, slot + 9, faded(primitive.fill, opacity))
        color(boxes, slot + 13, faded(primitive.borderColor, opacity))
        color(boxes, slot + 17, faded(primitive.side or primitive.fill, opacity))
        local clip = at.clip
        boxes[slot + 21], boxes[slot + 22], boxes[slot + 23], boxes[slot + 24] = clip[1], clip[2], clip[3], clip[4]
        boxes[slot + 25], boxes[slot + 26], boxes[slot + 27], boxes[slot + 28] =
          if primitive.edges then edgeWidth else 0, primitive.rotation, 0, 0
        count += 1
      elseif primitive.kind == 'image' then
        packed.images[#packed.images + 1] = {
          source = primitive.source,
          x = at.x + primitive.x,
          y = at.y + primitive.y,
          width = primitive.width,
          height = primitive.height,
          z = at.z + contentOffset + primitive.offset + step,
          tint = faded(primitive.tint, opacity),
          clip = at.clip,
        }
      else
        local tint = faded(primitive.color, opacity)
        local z = at.z + contentOffset + primitive.offset + step
        local left = at.x + primitive.x
        for _, line in primitive.lines do
          local baseline = at.y + primitive.y + line.baseline
          for _, shaped in line.glyphs do
            local placement = glyphs(shaped.face, shaped.id)
            if placement then
              glyph(
                placement,
                left + shaped.x + shaped.xOffset,
                baseline + shaped.yOffset,
                shaped.size,
                z,
                tint,
                at.clip
              )
            end
          end
        end
      end
    end
  end
  local panelOpacity = if panel.fade then math.clamp(panel.fade.value, 0, 1) else 1
  local function visit(node: records.Node, clip: { number }, inherited: number): ()
    if outside(clip, node) then
      return
    end
    local primitives = node.primitives or record.run(node, env, visuals)
    node.primitives = primitives
    local channel = node.channels.opacity
    local opacity = inherited * (if channel then math.clamp(channel.value, 0, 1) else 1)
    if opacity <= 0.005 then
      return
    end
    emit(primitives, {
      x = node.x,
      y = node.y,
      z = node.z,
      parentSurface = node.z - node.elevation - node.lift,
      clip = clip,
      opacity = opacity,
    })
    -- A node focused by traversal shows a ring in the accent colour just outside its box. Focus from a pointer press
    -- shows none, in the manner of the web's focus-visible.
    if node.host.focusVisible then
      local margin = tokens.sizes.headerRule * 1.5
      local ring = tokens.sizes.headerRule
      local slot = count * shader.SLOTS * 4
      boxes[slot + 1], boxes[slot + 2] = node.x - margin, node.y - margin
      boxes[slot + 3], boxes[slot + 4] = node.width + margin * 2, node.height + margin * 2
      boxes[slot + 5], boxes[slot + 6] = node.z + contentOffset * 2 + #primitives * PRIMITIVE_STEP, 0
      boxes[slot + 7], boxes[slot + 8] = tokens.radii.control + margin, ring
      color(boxes, slot + 9, TRANSPARENT)
      color(boxes, slot + 13, faded(tokens.colors.accent, opacity))
      color(boxes, slot + 17, TRANSPARENT)
      boxes[slot + 21], boxes[slot + 22], boxes[slot + 23], boxes[slot + 24] = clip[1], clip[2], clip[3], clip[4]
      boxes[slot + 25], boxes[slot + 26], boxes[slot + 27], boxes[slot + 28] = 0, 0, 0, 0
      count += 1
    end
    local childClip = if node.kind.registration.clip then intersect(clip, node) else clip
    for _, child in node.children do
      visit(child, childClip, opacity)
    end
  end
  if panel.root then
    visit(panel.root, UNCLIPPED, panelOpacity)
  end
  for _, ghost in panel.ghosts do
    local opacity = panelOpacity * math.clamp(ghost.opacity.value, 0, 1)
    for _, entry in ghost.nodes do
      emit(entry.primitives, {
        x = entry.x,
        y = entry.y,
        z = entry.z,
        parentSurface = entry.parentSurface,
        clip = entry.clip or UNCLIPPED,
        opacity = opacity,
      })
    end
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
