-- The shape of a panel's surface for hit testing: a plane, or a vertical cylinder of radius 1 / curve whose centre
-- lies on the viewer's side, as the shaders draw it. Panel x is measured along the arc from the panel's centre line.

local records = require './records'

local shape = {}

-- Maps a point in the panel's local frame, with the panel's centre at the origin, y up, and z towards the viewer, to
-- panel coordinates and a height above the surface along its normal.
function shape.toPanel(panel: records.Panel, x: number, y: number, z: number): (number, number, number)
  local curve = panel.curve
  if curve <= 0 then
    return x + panel.width / 2, panel.height / 2 - y, z
  end
  local radius = 1 / curve
  local angle = math.atan2(x, radius - z)
  local distance = math.sqrt(x * x + (radius - z) ^ 2)
  return angle * radius + panel.width / 2, panel.height / 2 - y, radius - distance
end

local function inside(panel: records.Panel, u: number, v: number): boolean
  return u >= 0 and v >= 0 and u <= panel.width and v <= panel.height
end

-- Where a ray in the panel's local frame meets the surface: panel coordinates and the distance along the ray, or nil.
-- A bounded hit must land on the panel; an unbounded one, for a capture that has left the panel, need not.
function shape.ray(
  panel: records.Panel,
  origin: vector,
  direction: vector,
  bounded: boolean
): (number?, number?, number?)
  local curve = panel.curve
  if curve <= 0 then
    if math.abs(direction.z) < 1e-9 then
      return nil, nil, nil
    end
    local t = -origin.z / direction.z
    if t <= 0 then
      return nil, nil, nil
    end
    local u, v = shape.toPanel(panel, origin.x + direction.x * t, origin.y + direction.y * t, 0)
    if bounded and not inside(panel, u, v) then
      return nil, nil, nil
    end
    return u, v, t * vector.magnitude(direction)
  end
  local radius = 1 / curve
  local ox, oz = origin.x, origin.z - radius
  local a = direction.x * direction.x + direction.z * direction.z
  if a < 1e-12 then
    return nil, nil, nil
  end
  local b = 2 * (ox * direction.x + oz * direction.z)
  local c = ox * ox + oz * oz - radius * radius
  local discriminant = b * b - 4 * a * c
  if discriminant < 0 then
    return nil, nil, nil
  end
  local root = math.sqrt(discriminant)
  -- Both crossings are tried nearest first; only the half of the cylinder that faces the centre holds the panel.
  for _, t in { (-b - root) / (2 * a), (-b + root) / (2 * a) } do
    if t > 0 then
      local x, y, z = origin.x + direction.x * t, origin.y + direction.y * t, origin.z + direction.z * t
      if radius - z > 0 then
        local u, v = shape.toPanel(panel, x, y, z)
        if not bounded or inside(panel, u, v) then
          return u, v, t * vector.magnitude(direction)
        end
      end
    end
  end
  return nil, nil, nil
end

-- The world pose of a point on the panel at an elevation, facing out of the surface there.
function shape.frame(panel: records.Panel, u: number, v: number, elevation: number): Mat4
  local x, y = u - panel.width / 2, panel.height / 2 - v
  local curve = panel.curve
  if curve <= 0 then
    return lovr.math.mat4(panel.pose):translate(x, y, elevation)
  end
  local radius = 1 / curve
  local angle = x * curve
  return lovr.math
    .mat4(panel.pose)
    :translate((radius - elevation) * math.sin(angle), y, radius - (radius - elevation) * math.cos(angle))
    :rotate(-angle, 0, 1, 0)
end

-- A world ray in the panel's local frame.
function shape.localRay(panel: records.Panel, origin: vector, direction: vector): (vector, vector)
  local inverse = lovr.math.mat4(panel.pose):invert()
  local ox, oy, oz = inverse:mul(origin.x, origin.y, origin.z)
  local tx, ty, tz = inverse:mul(origin.x + direction.x, origin.y + direction.y, origin.z + direction.z)
  return vector.pack(ox, oy, oz), vector.pack(tx - ox, ty - oy, tz - oz)
end

return shape
