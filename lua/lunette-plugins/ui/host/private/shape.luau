-- The shape of a panel's surface for hit testing: a plane, or a cylinder of radius 1 / |curve|, as the shaders draw
-- it. A positive curve puts the cylinder's centre on the viewer's side, so the panel bends towards the viewer; a
-- negative one puts it behind, so the panel bends away, as a bracelet wraps a wrist. The cylinder's axis lies in the
-- panel plane, turned anticlockwise from the panel's vertical by the panel's curve axis. Panel coordinates across the
-- axis are measured along the arc from the panel's centre line.

local records = require './records'

local shape = {}

-- The arc may wrap at most half a turn to either side of the centre line, so a panel wraps its cylinder once at most.
local HALF_ANGLE = math.pi

-- The curve the panel is drawn and hit with: its own, or less where its width across the axis would wrap the
-- cylinder more than once. Zero is flat.
function shape.curvature(panel: records.Panel): number
  local curve = panel.curve
  if curve == 0 then
    return 0
  end
  local axis = panel.curveAxis
  local across = math.abs(math.cos(axis)) * panel.width + math.abs(math.sin(axis)) * panel.height
  local limit = if across > 0 then 2 * HALF_ANGLE / across else math.huge
  return math.sign(curve) * math.min(math.abs(curve), limit)
end

-- Turns panel-frame x and y into the bend's frame, where the axis is vertical, or back with `back`.
local function turn(panel: records.Panel, x: number, y: number, back: boolean?): (number, number)
  local axis = if back then -panel.curveAxis else panel.curveAxis
  local c, s = math.cos(axis), math.sin(axis)
  return c * x + s * y, -s * x + c * y
end

-- Maps a point in the panel's local frame, with the panel's centre at the origin, y up, and z towards the viewer, to
-- panel coordinates and a height above the surface along its normal.
function shape.toPanel(panel: records.Panel, x: number, y: number, z: number): (number, number, number)
  local curve = shape.curvature(panel)
  if curve == 0 then
    return x + panel.width / 2, panel.height / 2 - y, z
  end
  local bx, by = turn(panel, x, y)
  local radius = 1 / curve
  local side = math.sign(curve)
  local angle = math.atan2(bx, side * (radius - z))
  local distance = math.sqrt(bx * bx + (radius - z) ^ 2)
  local fx, fy = turn(panel, angle * math.abs(radius), by, true)
  return fx + panel.width / 2, panel.height / 2 - fy, side * (math.abs(radius) - distance)
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
  local curve = shape.curvature(panel)
  if curve == 0 then
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
  local side = math.sign(curve)
  local ox = turn(panel, origin.x, origin.y)
  local dx = turn(panel, direction.x, direction.y)
  local oz = origin.z - radius
  local a = dx * dx + direction.z * direction.z
  if a < 1e-12 then
    return nil, nil, nil
  end
  local b = 2 * (ox * dx + oz * direction.z)
  local c = ox * ox + oz * oz - radius * radius
  local discriminant = b * b - 4 * a * c
  if discriminant < 0 then
    return nil, nil, nil
  end
  local root = math.sqrt(discriminant)
  -- Both crossings are tried nearest first; only the half of the cylinder on the panel's side of its axis holds the
  -- panel: the half towards the viewer for either sign.
  for _, t in { (-b - root) / (2 * a), (-b + root) / (2 * a) } do
    if t > 0 then
      local x, y, z = origin.x + direction.x * t, origin.y + direction.y * t, origin.z + direction.z * t
      if side * (radius - z) > 0 then
        local u, v = shape.toPanel(panel, x, y, z)
        if not bounded or inside(panel, u, v) then
          return u, v, t * vector.magnitude(direction)
        end
      end
    end
  end
  return nil, nil, nil
end

-- The panel's pose with its zoom: the transform from panel-frame metres to the world.
function shape.basis(panel: records.Panel): Mat4
  local scale = panel.scale
  return lovr.math.mat4(panel.pose):scale(scale, scale, scale)
end

-- The world pose of a point on the panel at an elevation, facing out of the surface there, with the panel's zoom.
function shape.frame(panel: records.Panel, u: number, v: number, elevation: number): Mat4
  local x, y = u - panel.width / 2, panel.height / 2 - v
  local curve = shape.curvature(panel)
  if curve == 0 then
    return shape.basis(panel):translate(x, y, elevation)
  end
  local bx, by = turn(panel, x, y)
  local radius = 1 / curve
  local angle = bx * curve
  local px, py = turn(panel, (radius - elevation) * math.sin(angle), by, true)
  local axis = panel.curveAxis
  return shape
    .basis(panel)
    :translate(px, py, radius - (radius - elevation) * math.cos(angle))
    :rotate(-angle, -math.sin(axis), math.cos(axis), 0)
end

-- A world ray in the panel's local frame.
function shape.localRay(panel: records.Panel, origin: vector, direction: vector): (vector, vector)
  local inverse = shape.basis(panel):invert()
  local ox, oy, oz = inverse:mul(origin.x, origin.y, origin.z)
  local tx, ty, tz = inverse:mul(origin.x + direction.x, origin.y + direction.y, origin.z + direction.z)
  return vector.pack(ox, oy, oz), vector.pack(tx - ox, ty - oy, tz - oz)
end

return shape
