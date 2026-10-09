-- Drawing uses panel state and callbacks supplied by the host to avoid a dependency cycle.

local lunette = require '@lunette'
local contracts = require '@lunette-contracts/panels'
local shape = require '@lunette-plugins/panels/shape'
local silhouette = require '@lunette-plugins/panels/silhouette'
local frame = require '@lunette-plugins/panels/frame'
local geometry = require '@lunette-plugins/theme/rounded-geometry'
local passState = require '@lunette-plugins/pass-state'

local draw = {}

export type Source =
  { read kind: 'window', read source: lunette.Window }
  | { read kind: 'monitor', read source: lunette.Monitor }

export type Outline = {
  width: number?,
  height: number?,
  radius: number?,
  curve: number?,
  headerHeight: number?,
  headerRadius: number?,
  thickness: number?,
  mesh: Mesh?,
}
export type Drawable = {
  read pose: Mat4,
  read width: number,
  read height: number,
  read curve: number,
  read title: string?,
  read highlighted: boolean,
  read granted: boolean?,
  read frame: frame.Record?,
  contour: silhouette.Cache?,
  mesh: Mesh?,
  meshKey: string?,
  meshCurve: number?,
  meshTransform: string?,
  outline: Outline?,
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

local function contentMesh(target: Drawable, transform: CaptureTransform, style: contracts.Style): Mesh?
  local bounds, profile, polygon, rounded = silhouette.get(target, style)
  local graphics = lovr.graphics
  if not graphics or not graphics.newMesh then
    if rounded or (transform ~= 'normal' and transform ~= 'undefined') then
      error('panels: rounded or transformed capture requires mesh drawing', 2)
    end
    return nil
  end
  local contour = target.contour
  if
    target.mesh
    and contour
    and target.meshKey == contour.key
    and target.meshCurve == target.curve
    and target.meshTransform == transform
  then
    return target.mesh
  end
  local key = if contour and contour.key then contour.key else geometry.key(bounds, profile)
  local vertices: { { number } }
  local indices: { number }
  if rounded then
    vertices, indices = shape.rounded(target.width, target.height, target.curve, polygon)
  elseif target.curve > 0 then
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
  local made = graphics.newMesh(#vertices)
  local ok, failure = pcall(function(): ()
    made:setVertices(vertices)
    made:setIndices(indices)
  end)
  if not ok then
    pcall(function(): ()
      made:release()
    end)
    error(failure, 0)
  end
  local previous = target.mesh
  target.mesh, target.meshKey = made, key
  target.meshCurve, target.meshTransform = target.curve, transform
  if previous then
    previous:release()
  end
  return made
end

function draw.content(target: Drawable, pass: Pass, style: contracts.Style, contentShader: (boolean) -> Shader?)
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
    local _, _, _, rounded = silhouette.get(target, style)
    local transformed = transform ~= 'normal' and transform ~= 'undefined'
    local mesh = if target.curve > 0 or transformed or rounded then contentMesh(target, transform, style) else nil
    if mesh then
      pass:draw(mesh, target.pose)
    else
      local previous = target.mesh
      target.mesh, target.meshKey = nil, nil
      if previous then
        previous:release()
      end
      local transform = lovr.math.newMat4():set(target.pose):scale(target.width, target.height, 1)
      pass:plane(transform, 'fill', 1, 1)
    end
  end)
end

function draw.border(target: Drawable, pass: Pass, style: contracts.Style): ()
  local attachment = target.frame
  local joined = frame.joined(attachment)
  local header = if joined and attachment then attachment.style else nil
  local color = if header
    then header.borderColor
    else if target.highlighted then style.borderHighlightColor else style.borderColor
  local thickness = if header then header.borderThickness else style.borderThickness
  if thickness == 0 then
    draw.clearOutline(target)
    return
  end
  local radius = if target.granted then 0 else silhouette.radius(target, style)
  local headerHeight, headerRadius =
    if header then header.headerHeight else 0, if header then header.headerRadius else 0
  local cache: Outline = target.outline or {}
  target.outline = cache
  if
    not cache.mesh
    or cache.width ~= target.width
    or cache.height ~= target.height
    or cache.radius ~= radius
    or cache.curve ~= target.curve
    or cache.headerHeight ~= headerHeight
    or cache.headerRadius ~= headerRadius
    or cache.thickness ~= thickness
  then
    local bodyBounds: geometry.Bounds = { x = 0, y = 0, width = target.width, height = target.height }
    local body = geometry.profile(bodyBounds, geometry.uniform(radius))
    local bounds: geometry.Bounds =
      { x = 0, y = -headerHeight, width = target.width, height = target.height + headerHeight }
    local profile = body
    if header then
      local top =
        geometry.profile({ x = 0, y = 0, width = target.width, height = headerHeight }, geometry.uniform(headerRadius))
      profile = {
        topLeft = top.topLeft,
        topRight = top.topRight,
        bottomRight = body.bottomRight,
        bottomLeft = body.bottomLeft,
      }
    end
    local points, triangles = geometry.ring(bounds, profile, thickness)
    local vertices, indices =
      shape.mapTriangles(target.width, target.height, target.curve, points, triangles, thickness)
    local made = lovr.graphics.newMesh(#vertices)
    local ok, failure = pcall(function(): ()
      made:setVertices(vertices)
      made:setIndices(indices)
    end)
    if not ok then
      pcall(function(): ()
        made:release()
      end)
      error(failure, 0)
    end
    local previous = cache.mesh
    cache.width, cache.height, cache.radius, cache.curve = target.width, target.height, radius, target.curve
    cache.headerHeight, cache.headerRadius, cache.thickness, cache.mesh = headerHeight, headerRadius, thickness, made
    if previous then
      previous:release()
    end
  end
  local depth = if header then header.borderDepth else style.borderDepth
  local pose = lovr.math.newMat4(target.pose):translate(0, 0, -depth)
  local mesh = cache.mesh
  if not mesh then
    error 'panels: an outline has no retained mesh'
  end
  passState.withRestore(pass, function(): ()
    pass:setShader()
    pass:setMaterial(nil)
    pass:setCullMode 'none'
    pass:setDepthTest 'gequal'
    pass:setDepthWrite(color[4] == 1)
    pass:setColor(color[1], color[2], color[3], color[4])
    pass:draw(mesh, pose)
  end)
end

function draw.clearOutline(target: { outline: Outline? }): ()
  local cache = target.outline
  target.outline = nil
  if cache and cache.mesh then
    cache.mesh:release()
  end
end

-- Chrome titles remain separate from a target-owned joined outline.
function draw.chrome(target: Drawable, pass: Pass, style: contracts.Style, font: Font)
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
