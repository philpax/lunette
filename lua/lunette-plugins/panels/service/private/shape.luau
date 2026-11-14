-- Pure geometry of a native curved panel: a cylinder of radius 1 / |curve| whose axis lies in the panel plane,
-- turned anticlockwise from the panel's vertical by the panel's curve axis, with the panel's centre on it at the
-- panel's pose and the extent across the axis measured along the arc. A positive curve puts the centre on the
-- viewer's side and a negative one behind; zero is flat. The cylinder maths is shared with the toolkit host.
--
-- This module also builds the CPU meshes the scene drawing uses; those are native-only.

local quad = require '@lunette-contracts/quad'
local geometry = require '@lunette-plugins/graphics/rounded-geometry'
local curved = require '@lunette-plugins/graphics/curved-surface'

local shape = {}

export type Curved = quad.Quad & {
  read curve: number,
  read curveAxis: number,
  read polygon: { geometry.Point }?,
}

-- How many flat strips the in-scene drawing of a curve is made of.
shape.SEGMENTS = 32

-- Returns the pixel coordinate, from the top-left and along the arc, and the distance along the ray where it meets
-- the arc's inner face, or nothing.
function shape.hit(target: Curved, origin: vector, direction: vector): (number?, number?, number?)
  local curve = target.curve
  if curve == 0 then
    local x, y, distance = quad.hit(target, origin, direction)
    if x and y and target.polygon then
      if
        not geometry.contains(
          target.polygon,
          x / target.pixelWidth * target.width,
          y / target.pixelHeight * target.height
        )
      then
        return nil, nil, nil
      end
    end
    return x, y, distance
  end
  if target.width <= 0 or target.height <= 0 or target.pixelWidth <= 0 or target.pixelHeight <= 0 then
    return nil, nil, nil
  end

  local inverse = lovr.math.mat4(target.pose):invert()
  local originX, originY, originZ = origin:unpack()
  local directionX, directionY, directionZ = direction:unpack()
  local ox, oy, oz = inverse:mul(originX, originY, originZ, 1)
  local dx, dy, dz = inverse:mul(directionX, directionY, directionZ, 0)
  local surface = curved.surface(target.width, target.height, curve, target.curveAxis)
  local u, v, distance = curved.ray(surface, vector.pack(ox, oy, oz), vector.pack(dx, dy, dz), true, target.backFace)
  if not u or not v then
    return nil, nil, nil
  end
  local pixelX = u / target.width * target.pixelWidth
  local pixelY = v / target.height * target.pixelHeight
  if
    target.polygon
    and not geometry.contains(
      target.polygon,
      pixelX / target.pixelWidth * target.width,
      pixelY / target.pixelHeight * target.height
    )
  then
    return nil, nil, nil
  end
  return pixelX, pixelY, distance
end

-- Maps a polygon in panel coordinates onto the surface and appends its triangles. The polygon is split along the
-- across-axis direction so no triangle spans more than one arc strip. The strip span comes from the polygon itself,
-- because an outline ring reaches beyond the panel by its thickness, and at a tilted axis its corner's `a` exceeds
-- the panel's own extent.
local function appendPolygon(
  vertices: { { number } },
  indices: { number },
  width: number,
  height: number,
  curve: number,
  axis: number,
  polygon: { geometry.Point },
  segments: number
): ()
  if #polygon < 3 then
    return
  end
  local surface = curved.surface(width, height, curve, axis)
  local minA: number, maxA: number, minB: number, maxB: number = math.huge, -math.huge, math.huge, -math.huge
  local bendPoints: { geometry.Point } = {}
  for _, point in polygon do
    local a, b = curved.bendOf(surface, point.x, point.y)
    bendPoints[#bendPoints + 1] = { x = a, y = b }
    minA, maxA = math.min(minA, a) :: number, math.max(maxA, a) :: number
    minB, maxB = math.min(minB, b) :: number, math.max(maxB, b) :: number
  end
  local span = maxA - minA
  local strips = if surface.curve ~= 0 and span > 0 then segments else 1
  for strip = 0, strips - 1 do
    local clipped = if strips == 1
      then bendPoints
      else geometry.clip(bendPoints, {
        x = minA + span * strip / strips,
        y = minB,
        width = span / strips,
        height = maxB - minB,
      })
    local points, triangles = geometry.triangles(clipped)
    local offset = #vertices
    for _, point in points do
      local u, v = curved.panelOf(surface, point[1], point[2])
      local x, y, z, nx, ny, nz = curved.point(surface, u, v)
      vertices[#vertices + 1] = { x, y, z, nx, ny, nz, u / width, v / height }
    end
    -- Source coordinates are y-down, whereas native panel coordinates are y-up.
    for index = 1, #triangles, 3 do
      indices[#indices + 1] = offset + triangles[index]
      indices[#indices + 1] = offset + triangles[index + 2]
      indices[#indices + 1] = offset + triangles[index + 1]
    end
  end
end

-- The vertices and triangle indices of the panel's rectangle on the surface, as LÖVR's default mesh format takes
-- them: position, normal out of the surface, and texture coordinate with the origin at the top-left.
function shape.arc(
  width: number,
  height: number,
  curve: number,
  axis: number,
  segments: number
): ({ { number } }, { number })
  local vertices: { { number } } = {}
  local indices: { number } = {}
  appendPolygon(vertices, indices, width, height, curve, axis, {
    { x = 0, y = 0 },
    { x = width, y = 0 },
    { x = width, y = height },
    { x = 0, y = height },
  }, segments)
  return vertices, indices
end

-- Rounded polygons are split before cylindrical mapping so no triangle spans multiple arc strips.
function shape.rounded(
  width: number,
  height: number,
  curve: number,
  axis: number,
  polygon: { geometry.Point }
): ({ { number } }, { number })
  local vertices: { { number } } = {}
  local indices: { number } = {}
  appendPolygon(vertices, indices, width, height, curve, axis, polygon, shape.SEGMENTS)
  return vertices, indices
end

-- Outline triangles are split at arc-strip boundaries as rounded polygons are; the ring's own perimeter carries its
-- thickness, so no separate expansion is applied.
function shape.mapTriangles(
  width: number,
  height: number,
  curve: number,
  axis: number,
  points: { { number } },
  triangles: { number }
): ({ { number } }, { number })
  local vertices: { { number } } = {}
  local indices: { number } = {}
  for index = 1, #triangles, 3 do
    local polygon: { geometry.Point } = {}
    for vertex = index, index + 2 do
      local point = points[triangles[vertex]]
      polygon[#polygon + 1] = { x = point[1], y = point[2] }
    end
    appendPolygon(vertices, indices, width, height, curve, axis, polygon, shape.SEGMENTS)
  end
  return vertices, indices
end

return shape
