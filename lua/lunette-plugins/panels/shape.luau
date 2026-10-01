-- Pure geometry of a curved panel: a piece of a vertical cylinder.
--
-- A curve is LÖVR's layer curve: the cylinder's radius is 1 / curve, its axis
-- is vertical, and its centre is in front of the panel, on the side a viewer
-- stands, so the panel wraps toward the viewer. The panel's centre lies on the
-- cylinder at the panel's pose, and its width is measured along the arc. A
-- curve of zero or less is a flat panel, which `@lunette-contracts/quad`
-- describes.

local quad = require '@lunette-contracts/quad'

local shape = {}

export type Curved = quad.Quad & {
  read curve: number,
}

-- How many flat strips the in-scene drawing of a curve is made of.
shape.SEGMENTS = 32

-- The half-angle the arc subtends, which never exceeds a half turn: a panel
-- wider than its cylinder's circumference wraps no further.
function shape.halfAngle(width: number, curve: number): number
  return math.min(width * curve / 2, math.pi)
end

-- Returns the pixel coordinate and the distance along the ray where it meets
-- the arc's inner face, or nothing. The pixel origin is the top-left corner,
-- as for a flat quad, and the horizontal coordinate is measured along the arc,
-- which is the width unless the width is wider than the circumference.
function shape.hit(target: Curved, origin: vector, direction: vector): (number?, number?, number?)
  local curve = target.curve
  if not (curve > 0) or curve == math.huge then
    return quad.hit(target, origin, direction)
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
        return pixelX, pixelY, distance
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

return shape
