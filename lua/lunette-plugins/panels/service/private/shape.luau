-- Pure geometry of a native curved panel, using LÖVR's layer curve: a vertical cylinder of radius 1 / curve with
-- its centre on the viewer's side, the panel's centre on it at the panel's pose, and the width measured along the
-- arc. A curve of zero or less is flat. The cylinder maths is shared with the toolkit host.
--
-- This module also builds the CPU meshes the scene drawing uses; those are native-only.

local quad = require '@lunette-contracts/quad'
local geometry = require '@lunette-plugins/graphics/rounded-geometry'
local curved = require '@lunette-plugins/graphics/curved-surface'

local shape = {}

export type Curved = quad.Quad & {
  read curve: number,
  read polygon: { geometry.Point }?,
}

-- How many flat strips the in-scene drawing of a curve is made of.
shape.SEGMENTS = 32

-- The half-angle the arc subtends, which never exceeds a half turn: a panel wider than its cylinder's circumference
-- wraps no further.
function shape.halfAngle(width: number, curve: number): number
  return curved.halfAngle(width, curve)
end

-- Returns the pixel coordinate, from the top-left and along the arc, and the distance along the ray where it meets
-- the arc's inner face, or nothing.
function shape.hit(target: Curved, origin: vector, direction: vector): (number?, number?, number?)
  local curve = target.curve
  if not (curve > 0) or curve == math.huge then
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
  local surface = curved.surface(target.width, target.height, curve, 0)
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

-- The vertices and triangle indices of the arc in the panel's space, as
-- LÖVR's default mesh format takes them: position, normal toward the axis,
-- and texture coordinate with the origin at the top-left.
function shape.arc(width: number, height: number, curve: number, segments: number): ({ { number } }, { number })
  -- The mesh takes the same half-turn clamp as the hit test and the layer, so a width past the limit draws once.
  local bounded = curved.curvature(width, height, math.max(curve, 0), 0)
  local radius = 1 / bounded
  local half = shape.halfAngle(width, bounded)
  local vertices: { { number } } = {}
  local indices: { number } = {}
  for index = 0, segments do
    local u = index / segments
    local angle = -half + 2 * half * u
    local x, z = radius * math.sin(angle), radius - radius * math.cos(angle)
    local nx, nz = -math.sin(angle), math.cos(angle)
    vertices[#vertices + 1] = { x, height / 2, z, nx, 0, nz, u, 0 }
    vertices[#vertices + 1] = { x, -height / 2, z, nx, 0, nz, u, 1 }
    if index < segments then
      local top, bottom = 2 * index + 1, 2 * index + 2
      local nextTop, nextBottom = top + 2, bottom + 2
      for _, vertex in ipairs { top, bottom, nextTop, nextTop, bottom, nextBottom } do
        indices[#indices + 1] = vertex
      end
    end
  end
  return vertices, indices
end

-- Triangulates a polygon in source coordinates and appends it as mesh vertices, flat or on the cylinder.
local function appendPolygon(
  vertices: { { number } },
  indices: { number },
  width: number,
  height: number,
  curve: number,
  polygon: { geometry.Point }
): ()
  local points, triangles = geometry.triangles(polygon)
  local offset = #vertices
  for _, point in points do
    local u, v = point[1] / width, point[2] / height
    if curve > 0 then
      local radius = 1 / curve
      local angle = (2 * u - 1) * shape.halfAngle(width, curve)
      vertices[#vertices + 1] = {
        radius * math.sin(angle),
        height / 2 - point[2],
        radius - radius * math.cos(angle),
        -math.sin(angle),
        0,
        math.cos(angle),
        u,
        v,
      }
    else
      vertices[#vertices + 1] = { point[1] - width / 2, height / 2 - point[2], 0, 0, 0, 1, u, v }
    end
  end
  -- Source coordinates are y-down, whereas native panel coordinates are y-up.
  for index = 1, #triangles, 3 do
    indices[#indices + 1] = offset + triangles[index]
    indices[#indices + 1] = offset + triangles[index + 2]
    indices[#indices + 1] = offset + triangles[index + 1]
  end
end

-- Rounded polygons are split before cylindrical mapping so no triangle spans multiple arc strips.
function shape.rounded(
  width: number,
  height: number,
  curve: number,
  polygon: { geometry.Point }
): ({ { number } }, { number })
  local vertices: { { number } } = {}
  local indices: { number } = {}
  local bounded = curved.curvature(width, height, math.max(curve, 0), 0)
  local strips = if bounded > 0 then shape.SEGMENTS else 1
  for strip = 0, strips - 1 do
    local clipped = if strips == 1
      then polygon
      else geometry.clip(polygon, {
        x = width * strip / strips,
        y = 0,
        width = width / strips,
        height = height,
      })
    appendPolygon(vertices, indices, width, height, bounded, clipped)
  end
  return vertices, indices
end

-- Outline triangles also split at arc-strip boundaries; the outermost strips include border expansion.
function shape.mapTriangles(
  width: number,
  height: number,
  curve: number,
  points: { { number } },
  triangles: { number },
  expansion: number
): ({ { number } }, { number })
  local vertices: { { number } } = {}
  local indices: { number } = {}
  local bounded = curved.curvature(width, height, math.max(curve, 0), 0)
  for index = 1, #triangles, 3 do
    local polygon: { geometry.Point } = {}
    local top: number = math.huge
    local bottom: number = -math.huge
    for vertex = index, index + 2 do
      local point = points[triangles[vertex]]
      polygon[#polygon + 1] = { x = point[1], y = point[2] }
      top = math.min(top, point[2])
      bottom = math.max(bottom, point[2])
    end
    if bounded > 0 then
      for strip = 0, shape.SEGMENTS - 1 do
        local left = if strip == 0 then -expansion else width * strip / shape.SEGMENTS
        local right = if strip == shape.SEGMENTS - 1 then width + expansion else width * (strip + 1) / shape.SEGMENTS
        appendPolygon(
          vertices,
          indices,
          width,
          height,
          bounded,
          geometry.clip(polygon, { x = left, y = top, width = right - left, height = bottom - top })
        )
      end
    else
      appendPolygon(vertices, indices, width, height, bounded, polygon)
    end
  end
  return vertices, indices
end

return shape
