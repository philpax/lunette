-- Pure cylinder geometry for a curved panel, shared by the native panel service and the toolkit host. Panel-frame
-- coordinates have their origin at the panel's centre, x right, y up, and z towards the viewer, in metres. A positive
-- curve puts the cylinder's centre on the viewer's side, so the panel bends towards them; a negative curve puts it
-- behind. The axis lies in the panel plane, turned anticlockwise from the panel's vertical by the surface's axis.

local curved = {}

export type Surface = {
  read width: number,
  read height: number,
  read curve: number,
  read axis: number,
}

-- The arc wraps at most half a turn to either side of the centre line, so a panel wraps its cylinder once at most.
local HALF_TURN = math.pi

-- The panel's extent across the cylinder's axis.
function curved.across(width: number, height: number, axis: number): number
  return math.abs(math.cos(axis)) * width + math.abs(math.sin(axis)) * height
end

-- The greatest curve at which an extent across the axis wraps no more than half a turn either side.
function curved.limit(extent: number): number
  return if extent > 0 then 2 * HALF_TURN / extent else math.huge
end

-- The half-angle the arc subtends for an extent across the axis; it never exceeds a half turn.
function curved.halfAngle(extent: number, curve: number): number
  return math.min(math.abs(curve) * extent / 2, HALF_TURN)
end

-- The curve the panel is drawn and hit with: its own, reduced where the width across the axis would wrap the
-- cylinder more than once. Zero is flat.
function curved.curvature(width: number, height: number, curve: number, axis: number): number
  if curve == 0 then
    return 0
  end
  local extent = curved.across(width, height, axis)
  local limit = curved.limit(extent)
  return math.sign(curve) * math.min(math.abs(curve), limit)
end

function curved.surface(width: number, height: number, curve: number, axis: number): Surface
  return {
    width = width,
    height = height,
    curve = curved.curvature(width, height, curve, axis),
    axis = axis,
  }
end

-- An axis angle in radians, wrapped into (-pi, pi] so equivalent angles compare and persist canonically. A
-- non-finite angle is a caller error.
function curved.normalizeAxis(angle: number): number
  assert(
    type(angle) == 'number' and angle == angle and math.abs(angle) < math.huge,
    'curved: an axis is a finite angle'
  )
  local wrapped = angle % (2 * HALF_TURN)
  if wrapped > HALF_TURN then
    wrapped -= 2 * HALF_TURN
  elseif wrapped <= -HALF_TURN then
    wrapped += 2 * HALF_TURN
  end
  return wrapped
end

-- Turns panel-frame x and y into the bend's frame, where the axis is vertical, or back with `back`.
local function turn(axis: number, x: number, y: number, back: boolean?): (number, number)
  local angle = if back then -axis else axis
  local c, s = math.cos(angle), math.sin(angle)
  return c * x + s * y, -s * x + c * y
end

-- A point in panel coordinates in the bend's frame: `a` runs across the cylinder's axis, in the direction the
-- curve bends, and `b` runs along the axis.
function curved.bendOf(surface: Surface, u: number, v: number): (number, number)
  return turn(surface.axis, u - surface.width / 2, surface.height / 2 - v)
end

-- The inverse of `curved.bendOf`: panel coordinates from the bend frame.
function curved.panelOf(surface: Surface, a: number, b: number): (number, number)
  local x, y = turn(surface.axis, a, b, true)
  return x + surface.width / 2, surface.height / 2 - y
end

-- The position and outward unit normal, in the panel's frame, of a point at panel coordinates on the surface.
function curved.point(surface: Surface, u: number, v: number): (number, number, number, number, number, number)
  local width, height, axis = surface.width, surface.height, surface.axis
  local x, y = u - width / 2, height / 2 - v
  local curve = surface.curve
  if curve == 0 then
    return x, y, 0, 0, 0, 1
  end
  local bx, by = turn(axis, x, y)
  local radius = 1 / curve
  local angle = bx * curve
  local px, py = turn(axis, radius * math.sin(angle), by, true)
  local nx, ny = -math.cos(axis) * math.sin(angle), -math.sin(axis) * math.sin(angle)
  return px, py, radius - radius * math.cos(angle), nx, ny, math.cos(angle)
end

-- Maps a point in the panel's frame to panel coordinates and a height above the surface along its normal. Panel
-- coordinates are metres from the top-left corner, with x right and y down.
function curved.toPanel(surface: Surface, x: number, y: number, z: number): (number, number, number)
  local width, height, axis = surface.width, surface.height, surface.axis
  local curve = surface.curve
  if curve == 0 then
    return x + width / 2, height / 2 - y, z
  end
  local bx, by = turn(axis, x, y)
  local radius = 1 / curve
  local side = math.sign(curve)
  local angle = math.atan2(bx, side * (radius - z))
  local distance = math.sqrt(bx * bx + (radius - z) ^ 2)
  local fx, fy = turn(axis, angle * math.abs(radius), by, true)
  return fx + width / 2, height / 2 - fy, side * (math.abs(radius) - distance)
end

local function inside(surface: Surface, u: number, v: number): boolean
  return u >= 0 and v >= 0 and u <= surface.width and v <= surface.height
end

-- Where a ray in the panel's frame meets the surface: panel coordinates and the distance along the ray, or nothing.
-- A bounded hit must land on the panel; an unbounded one, for a capture that has left the panel, need not. A
-- back-face hit reaches the far side of the cylinder, as a panel that answers rays from behind accepts.
function curved.ray(
  surface: Surface,
  origin: vector,
  direction: vector,
  bounded: boolean,
  backFace: boolean?
): (number?, number?, number?)
  if surface.width <= 0 or surface.height <= 0 then
    return nil, nil, nil
  end
  local curve = surface.curve
  if curve == 0 then
    if math.abs(direction.z) < 1e-9 then
      return nil, nil, nil
    end
    local t = -origin.z / direction.z
    if t <= 0 then
      return nil, nil, nil
    end
    local u, v = curved.toPanel(surface, origin.x + direction.x * t, origin.y + direction.y * t, 0)
    if bounded and not inside(surface, u, v) then
      return nil, nil, nil
    end
    return u, v, t * vector.magnitude(direction)
  end
  local axis = surface.axis
  local radius = 1 / curve
  local side = math.sign(curve)
  local ox = turn(axis, origin.x, origin.y)
  local dx = turn(axis, direction.x, direction.y)
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
  -- Both crossings are tried nearest first. The panel's face is the one a ray from the viewer meets on its way in:
  -- the near half of the cylinder, whose normal turns towards the ray.
  for _, t in { (-b - root) / (2 * a), (-b + root) / (2 * a) } do
    if t > 0 then
      local x, y, z = origin.x + direction.x * t, origin.y + direction.y * t, origin.z + direction.z * t
      local outward = x * direction.x + (z - radius) * direction.z
      if side * outward > 0 or backFace == true then
        local u, v = curved.toPanel(surface, x, y, z)
        if not bounded or inside(surface, u, v) then
          return u, v, t * vector.magnitude(direction)
        end
      end
    end
  end
  return nil, nil, nil
end

-- The pose in the panel's frame of a point on the panel at an elevation, facing out of the surface there.
function curved.frame(surface: Surface, u: number, v: number, elevation: number): Mat4
  local width, height, axis = surface.width, surface.height, surface.axis
  local x, y = u - width / 2, height / 2 - v
  local curve = surface.curve
  if curve == 0 then
    return lovr.math.newMat4():translate(x, y, elevation)
  end
  local bx, by = turn(axis, x, y)
  local radius = 1 / curve
  local angle = bx * curve
  local px, py = turn(axis, (radius - elevation) * math.sin(angle), by, true)
  return lovr.math
    .newMat4()
    :translate(px, py, radius - (radius - elevation) * math.cos(angle))
    :rotate(-angle, -math.sin(axis), math.cos(axis), 0)
end

return curved
