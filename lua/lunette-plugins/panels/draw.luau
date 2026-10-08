-- Drawing uses panel state and callbacks supplied by the host to avoid a dependency cycle.

local lunette = require '@lunette'
local contracts = require '@lunette-contracts/panels'
local shape = require '@lunette-plugins/panels/shape'
local passState = require '@lunette-plugins/pass-state'

local draw = {}

export type Source =
  { read kind: 'window', read source: lunette.Window }
  | { read kind: 'monitor', read source: lunette.Monitor }

export type Drawable = {
  read pose: Mat4,
  read width: number,
  read height: number,
  read curve: number,
  read title: string?,
  read highlighted: boolean,
  mesh: Mesh?,
  meshKey: string?,
} & Source

type CaptureTransform =
  'normal'
  | 'undefined'
  | 'rot90'
  | 'rot180'
  | 'rot270'
  | 'flipped'
  | 'flipped90'
  | 'flipped180'
  | 'flipped270'

-- These are the UV permutations used by WayVR's ScreenPipeline.
local function transformUv(u: number, v: number, transform: CaptureTransform): (number, number)
  if transform == 'rot90' then
    return v, 1 - u
  elseif transform == 'rot180' then
    return 1 - u, 1 - v
  elseif transform == 'rot270' then
    return 1 - v, u
  elseif transform == 'flipped' then
    return 1 - u, v
  elseif transform == 'flipped90' then
    return v, u
  elseif transform == 'flipped180' then
    return u, 1 - v
  elseif transform == 'flipped270' then
    return 1 - v, 1 - u
  end
  return u, v
end

-- Identity curved panels can fall back to a flat quad without changing orientation.
local function contentMesh(target: Drawable, transform: CaptureTransform): Mesh?
  local graphics = lovr.graphics
  if not graphics or not graphics.newMesh then
    if transform ~= 'normal' and transform ~= 'undefined' then
      error('panels: transformed capture requires mesh drawing', 2)
    end
    return nil
  end
  local topology = if target.curve > 0 then 'arc' else 'flat'
  local key = string.format('%s %.9g %.9g %.9g %s', topology, target.width, target.height, target.curve, transform)
  local mesh = target.mesh
  if mesh and target.meshKey == key then
    return mesh
  end
  local vertices: { { number } }
  local indices: { number }
  if target.curve > 0 then
    vertices, indices = shape.arc(target.width, target.height, target.curve, shape.SEGMENTS)
  else
    local w, h = target.width / 2, target.height / 2
    vertices = {
      { -w, h, 0, 0, 0, 1, 0, 0 },
      { -w, -h, 0, 0, 0, 1, 0, 1 },
      { w, h, 0, 0, 0, 1, 1, 0 },
      { w, -h, 0, 0, 0, 1, 1, 1 },
    }
    indices = { 1, 2, 3, 3, 2, 4 }
  end
  for _, vertex in vertices do
    vertex[7], vertex[8] = transformUv(vertex[7], vertex[8], transform)
  end
  local reusable = mesh and target.meshKey and string.sub(target.meshKey, 1, #topology + 1) == topology .. ' '
  local made: Mesh = if reusable and mesh then mesh else graphics.newMesh(#vertices)
  target.mesh = made
  made:setVertices(vertices)
  made:setIndices(indices)
  target.meshKey = key
  return made
end

function draw.content(target: Drawable, pass: Pass, contentShader: (boolean) -> Shader?)
  local texture: Texture | false
  local opaque = true
  local transform: CaptureTransform = 'normal'
  local described: Source = target
  if described.kind == 'window' then
    local window = described.source
    texture = window:getTexture()
    opaque = window.opaque
  else
    texture = described.source:getTexture()
    local captured = described.source.frameTransform
    if captured ~= nil then
      transform = captured
    end
  end
  if not texture then
    return
  end

  local sampled: Texture = texture
  local shader = contentShader(opaque)
  passState.withRestore(pass, function()
    pass:setBlendMode('alpha', 'premultiplied')
    if shader then
      pass:setShader(shader)
    else
      pass:setShader()
    end
    pass:setMaterial(sampled)
    local transformed = transform ~= 'normal' and transform ~= 'undefined'
    local mesh = if target.curve > 0 or transformed then contentMesh(target, transform) else nil
    if mesh then
      pass:draw(mesh, target.pose)
    else
      local transform = lovr.math.newMat4():set(target.pose):scale(target.width, target.height, 1)
      pass:plane(transform, 'fill', 1, 1)
    end
  end)
end

-- Chrome draws the border and title. Other decorations belong to consumers.
function draw.chrome(target: Drawable, pass: Pass, style: contracts.Style, font: Font)
  local color = target.highlighted and style.borderHighlightColor or style.borderColor

  pass:setColor(color[1], color[2], color[3], color[4])
  local borderTransform = lovr.math
    .newMat4()
    :set(target.pose)
    :translate(0, 0, -style.borderDepth)
    :scale(target.width + style.borderThickness * 2, target.height + style.borderThickness * 2, 1)
  pass:plane(borderTransform, 'fill', 1, 1)

  local title: string? = target.title
  if not title then
    title = if target.kind == 'window' then target.source.title else target.source.name
  end
  if title then
    pass:setColor(style.titleColor[1], style.titleColor[2], style.titleColor[3], style.titleColor[4])
    local above = lovr.math
      .mat4(target.pose)
      :translate(0, target.height / 2 + style.titleMargin + style.titleHeight / 2, 0)
      :scale(vector.pack(style.titleHeight / font:getHeight()))
    pass:text(title, above, 0, 'center', 'middle')
  end
  pass:setColor(1, 1, 1, 1)
end

return draw
