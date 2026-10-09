-- Pure geometry of a curved panel, using LÖVR's layer curve: a vertical cylinder of radius 1 / curve with
-- its centre on the viewer's side, the panel's centre on it at the panel's pose, and the width measured
-- along the arc. A curve of zero or less is flat.

local quad = require '@lunette-contracts/quad'
local geometry = require '@lunette-plugins/theme/rounded-geometry'

local shape = {}

export type Curved = quad.Quad & {
  read curve: number,
  read polygon: { geometry.Point }?,
}

-- How many flat strips the in-scene drawing of a curve is made of.
shape.SEGMENTS = 32

-- The half-angle the arc subtends, which never exceeds a half turn: a panel
-- wider than its cylinder's circumference wraps no further.
function shape.halfAngle(width: number, curve: number): number
  return math.min(width * curve / 2, math.pi)
end

-- Returns the pixel coordinate, from the top-left and along the arc, and the distance along the ray where
-- it meets the arc's inner face, or nothing.
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
  local radius = 1 / curve
  local half = shape.halfAngle(target.width, curve)

  local originX, originY, originZ = origin:unpack()
  local directionX, directionY, directionZ = direction:unpack()
  local inverse = lovr.math.mat4(target.pose):invert()
  local ox, oy, oz = inverse:mul(originX, originY, originZ, 1)
  local dx, dy, dz = inverse:mul(directionX, directionY, directionZ, 0)

  -- The circle in the horizontal plane, centred at (0, radius) in x and z.
  local a = dx * dx + dz * dz
  if a == 0 then
    return nil, nil, nil
  end
  local cz = oz - radius
  local b = 2 * (ox * dx + cz * dz)
  local c = ox * ox + cz * cz - radius * radius
  local discriminant = b * b - 4 * a * c
  if discriminant < 0 then
    return nil, nil, nil
  end
  local root = math.sqrt(discriminant)
  for _, distance in ipairs { (-b - root) / (2 * a), (-b + root) / (2 * a) } do
    if distance > 0 then
      local x, y, z = ox + distance * dx, oy + distance * dy, oz + distance * dz
      local angle = math.atan2(x, radius - z)
      -- The inner face is the one a ray leaving the axis meets.
      local outward = x * dx + (z - radius) * dz
      local front = outward > 0 or target.backFace
      if front and math.abs(angle) <= half and math.abs(y) <= target.height / 2 then
        local pixelX = (angle + half) / (2 * half) * target.pixelWidth
        local pixelY = (target.height / 2 - y) / target.height * target.pixelHeight
        if
          not target.polygon
          or geometry.contains(
            target.polygon,
            pixelX / target.pixelWidth * target.width,
            pixelY / target.pixelHeight * target.height
          )
        then
          return pixelX, pixelY, distance
        end
      end
    end
  end
  return nil, nil, nil
end

-- The vertices and triangle indices of the arc in the panel's space, as
-- LÖVR's default mesh format takes them: position, normal toward the axis,
-- and texture coordinate with the origin at the top-left.
function shape.arc(width: number, height: number, curve: number, segments: number): ({ { number } }, { number })
  local radius = 1 / curve
  local half = shape.halfAngle(width, curve)
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
  local strips = if curve > 0 then shape.SEGMENTS else 1
  for strip = 0, strips - 1 do
    local clipped = if strips == 1
      then polygon
      else geometry.clip(polygon, {
        x = width * strip / strips,
        y = 0,
        width = width / strips,
        height = height,
      })
    appendPolygon(vertices, indices, width, height, curve, clipped)
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
    if curve > 0 then
      for strip = 0, shape.SEGMENTS - 1 do
        local left = if strip == 0 then -expansion else width * strip / shape.SEGMENTS
        local right = if strip == shape.SEGMENTS - 1 then width + expansion else width * (strip + 1) / shape.SEGMENTS
        appendPolygon(
          vertices,
          indices,
          width,
          height,
          curve,
          geometry.clip(polygon, { x = left, y = top, width = right - left, height = bottom - top })
        )
      end
    else
      appendPolygon(vertices, indices, width, height, curve, polygon)
    end
  end
  return vertices, indices
end

return shape
