-- Drawing one panel: its content on the flat quad or the arc, and its chrome. It takes what it reads rather
-- than the panel's host, so panel.luau can require it without a cycle.

local lunette = require '@lunette'
local contracts = require '@lunette-contracts/panels'
local shape = require '@lunette-plugins/panels/shape'

local draw = {}

export type Source =
  { read kind: 'window', read source: lunette.Window }
  | { read kind: 'monitor', read source: lunette.Monitor }

-- What drawing reads of a panel, and the mesh it keeps on it.
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

-- The arc mesh of a curved panel, made when first drawn and remade when the
-- panel's size or curve changes. Nil where the graphics module cannot make
-- one, and the panel is then drawn flat.
local function arcMesh(target: Drawable): Mesh?
  local graphics = lovr.graphics
  if not graphics or not graphics.newMesh then
    return nil
  end
  local key = string.format('%.9g %.9g %.9g', target.width, target.height, target.curve)
  local mesh = target.mesh
  if mesh and target.meshKey == key then
    return mesh
  end
  local vertices, indices = shape.arc(target.width, target.height, target.curve, shape.SEGMENTS)
  local made: Mesh = if mesh then mesh else graphics.newMesh(#vertices)
  target.mesh = made
  made:setVertices(vertices)
  made:setIndices(indices)
  target.meshKey = key
  return made
end

-- The default drawing: the source's texture on the flat quad, or on the arc a
-- positive curve gives.
function draw.content(target: Drawable, pass: Pass, opaqueShader: () -> Shader?)
  local texture: Texture | false
  local shader: Shader?
  local described: Source = target
  if described.kind == 'window' then
    local window = described.source
    texture = window:getTexture()
    if window.opaque then
      shader = opaqueShader()
    end
  else
    texture = described.source:getTexture()
  end
  if not texture then
    return
  end

  pass:setBlendMode('alpha', 'premultiplied')
  if shader then
    pass:setShader(shader)
  end

  pass:setMaterial(texture)
  local mesh = if target.curve > 0 then arcMesh(target) else nil
  if mesh then
    pass:draw(mesh, target.pose)
  else
    local transform = lovr.math.newMat4():set(target.pose):scale(target.width, target.height, 1)
    pass:plane(transform, 'fill', 1, 1)
  end
  pass:setMaterial(nil)
  if shader then
    pass:setShader()
  end
  pass:setBlendMode('alpha', 'alphamultiply')
end

-- A border and the title above the panel, drawn when the panel's chrome is
-- on. Decorations a configuration chooses are a consumer's, not this.
function draw.chrome(target: Drawable, pass: Pass, style: contracts.Style)
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
      :scale(vector.pack(style.titleHeight))
    pass:text(title, above, 0, 'center', 'middle')
  end
  pass:setColor(1, 1, 1, 1)
end

return draw
