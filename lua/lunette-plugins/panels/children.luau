-- A window's popups and subsurfaces, drawn beneath or over its content where the compositor routes the pointer.
--
-- A child is clipped to the panel's silhouette, because picking reaches only the window's own area: a part
-- drawn outside it could be seen and not pointed at. Each child keeps its mesh while its placement, its crop,
-- and the panel's shape are unchanged.

local lunette = require '@lunette'
local geometry = require '@lunette-plugins/graphics/rounded-geometry'
local shape = require '@lunette-plugins/panels/shape'

local children = {}

-- How far apart in depth successive layers of a window are drawn, in metres. Coplanar quads z-fight.
children.SEPARATION = 0.0002

export type Target = { read width: number, read height: number, read curve: number }

type Placed = {
  read x: number,
  read y: number,
  read width: number,
  read height: number,
  read crop: lunette.Crop,
}

type Entry = { mesh: Mesh, key: string }

-- Each child's mesh by the child's surface id.
export type Cache = { [number]: Entry }

local area: ({ geometry.Point }) -> number
local meshFor: (Drawing, lunette.ChildSurface) -> Entry?

-- The mesh of a child clipped to the panel's `polygon`, in panel metres from the top-left, with texture
-- coordinates in the child's crop. Nothing when no part of the child lies inside the polygon.
function children.geometry(
  target: Target,
  polygon: { geometry.Point },
  windowWidth: number,
  windowHeight: number,
  child: Placed
): ({ { number } }?, { number }?)
  if not (windowWidth > 0 and windowHeight > 0 and child.width > 0 and child.height > 0) then
    return nil, nil
  end
  local scaleX, scaleY = target.width / windowWidth, target.height / windowHeight
  local bounds: geometry.Bounds = {
    x = child.x * scaleX,
    y = child.y * scaleY,
    width = child.width * scaleX,
    height = child.height * scaleY,
  }
  local clipped = geometry.clip(polygon, bounds)
  if area(clipped) <= 0 then
    return nil, nil
  end
  local vertices, indices = shape.rounded(target.width, target.height, target.curve, clipped)
  if #indices == 0 then
    return nil, nil
  end
  local crop = child.crop
  for _, vertex in vertices do
    local u = (vertex[7] * target.width - bounds.x) / bounds.width
    local v = (vertex[8] * target.height - bounds.y) / bounds.height
    vertex[7], vertex[8] = crop.x + u * crop.width, crop.y + v * crop.height
  end
  return vertices, indices
end

export type Drawing = {
  read target: Target,
  read pose: Mat4,
  read polygon: { geometry.Point },
  -- What the polygon was built from, so a mesh is rebuilt when the panel's shape changes.
  read shapeKey: string,
  read windowWidth: number,
  read windowHeight: number,
  read cache: Cache,
  read shader: (opaque: boolean) -> Shader?,
  read newMesh: ({ { number } }, { number }) -> Mesh,
}

-- Draws the children on one side of the window, in their order, each a little further toward the viewer
-- than the last and all on their side of the window. Records the ids drawn in `drawn`, which
-- `children.prune` keeps.
function children.draw(
  pass: Pass,
  drawing: Drawing,
  list: { lunette.ChildSurface },
  below: boolean,
  drawn: { number }
): ()
  local count = 0
  for _, child in list do
    if child.below == below then
      count += 1
    end
  end
  local layer = 0
  for _, child in list do
    if child.below ~= below then
      continue
    end
    layer += 1
    local entry = meshFor(drawing, child)
    local shader = drawing.shader(child.opaque)
    if entry and shader then
      drawn[#drawn + 1] = child.id
      local depth = children.SEPARATION * (if below then layer - count - 1 else layer)
      pass:setShader(shader)
      pass:setMaterial(child.texture)
      pass:draw(entry.mesh, lovr.math.mat4(drawing.pose):translate(0, 0, depth))
    end
  end
end

-- Releases the meshes of children not in `kept`, and of every child when `kept` is absent.
function children.prune(cache: Cache, kept: { number }?): ()
  local keep: { [number]: boolean } = {}
  for _, id in kept or {} do
    keep[id] = true
  end
  local released: { Mesh } = {}
  for id, entry in cache do
    if not keep[id] then
      cache[id] = nil
      released[#released + 1] = entry.mesh
    end
  end
  for _, mesh in released do
    mesh:release()
  end
end

-- The polygon's area, which clipping leaves zero for a child that only touches the silhouette.
area = function(polygon: { geometry.Point }): number
  local twice = 0
  for index, point in polygon do
    local following = polygon[index % #polygon + 1]
    twice += point.x * following.y - following.x * point.y
  end
  return math.abs(twice) / 2
end

meshFor = function(drawing: Drawing, child: lunette.ChildSurface): Entry?
  local crop = child.crop
  local key = table.concat({
    drawing.shapeKey,
    drawing.target.width,
    drawing.target.height,
    drawing.target.curve,
    drawing.windowWidth,
    drawing.windowHeight,
    child.x,
    child.y,
    child.width,
    child.height,
    crop.x,
    crop.y,
    crop.width,
    crop.height,
  }, ',')
  local cached = drawing.cache[child.id]
  if cached and cached.key == key then
    return cached
  end
  local vertices, indices =
    children.geometry(drawing.target, drawing.polygon, drawing.windowWidth, drawing.windowHeight, child)
  local entry: Entry? = nil
  if vertices and indices then
    entry = { mesh = drawing.newMesh(vertices, indices), key = key }
  end
  drawing.cache[child.id] = entry
  if cached then
    cached.mesh:release()
  end
  return entry
end

return children
