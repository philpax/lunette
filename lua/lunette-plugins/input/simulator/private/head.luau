-- The simulated head as a position and a yaw and pitch, turned by mouse drags and moved by keys. Every function is
-- pure; the plugin reads the input and writes the pose.

local head = {}

-- Yaw turns left about +Y and pitch turns up about +X, both in radians, applied yaw first. Zero faces -Z.
export type State = {
  read position: vector,
  read yaw: number,
  read pitch: number,
}

export type Keys = {
  read forward: boolean,
  read backward: boolean,
  read left: boolean,
  read right: boolean,
  read up: boolean,
  read down: boolean,
  read sprint: boolean,
  read walk: boolean,
}

export type Speeds = {
  read speed: number,
  read sprintSpeed: number,
  read walkSpeed: number,
}

local LIMIT = math.pi / 2

-- The state of a head at `position` looking along `forward`, which need not be a unit vector.
function head.fromPose(position: vector, forward: vector): State
  local x, y, z = vector.unpack(vector.normalize(forward))
  return table.freeze {
    position = position,
    yaw = math.atan2(-x, -z),
    pitch = math.asin(math.clamp(y, -1, 1)),
  }
end

-- The view's half-angles in radians, as `lovr.headset.getViewAngles` reports them: each is positive away from the
-- view's centre.
export type View = {
  read left: number,
  read right: number,
  read up: number,
  read down: number,
}

-- The angles right of and above the view's centre at which a window point appears, with y growing downward.
local function angles(x: number, y: number, width: number, height: number, view: View): (number, number)
  local tx = -math.tan(view.left) + x / width * (math.tan(view.right) + math.tan(view.left))
  local ty = math.tan(view.up) - y / height * (math.tan(view.up) + math.tan(view.down))
  return math.atan(tx), math.atan(ty)
end

-- The turn that keeps the scene under a cursor dragged from (x0, y0) to (x1, y1) in window pixels, scaled by
-- `scale`: a drag right turns the view left, as if the scene were held and pulled. Answers the yaw and pitch to add.
function head.drag(
  x0: number,
  y0: number,
  x1: number,
  y1: number,
  width: number,
  height: number,
  view: View,
  scale: number
): (number, number)
  local yaw0, pitch0 = angles(x0, y0, width, height, view)
  local yaw1, pitch1 = angles(x1, y1, width, height, view)
  return (yaw1 - yaw0) * scale, (pitch0 - pitch1) * scale
end

-- Turns the head by angles in radians. Pitch stops at straight up and straight down.
function head.turn(state: State, yaw: number, pitch: number): State
  return table.freeze {
    position = state.position,
    yaw = state.yaw + yaw,
    pitch = math.clamp(state.pitch + pitch, -LIMIT, LIMIT),
  }
end

-- Rotates a vector in the head's frame into the world: pitch about X, then yaw about Y.
function head.rotate(state: State, local_: vector): vector
  local x, y, z = vector.unpack(local_)
  local cp, sp = math.cos(state.pitch), math.sin(state.pitch)
  y, z = y * cp - z * sp, y * sp + z * cp
  local cy, sy = math.cos(state.yaw), math.sin(state.yaw)
  return vector.pack(x * cy + z * sy, y, -x * sy + z * cy)
end

-- Moves the head along its own axes, as a flying camera does, at the speed the held modifier selects. Opposite keys
-- cancel, and a diagonal is no faster than a straight move.
function head.move(state: State, keys: Keys, speeds: Speeds, dt: number): State
  local x = (if keys.right then 1 else 0) - (if keys.left then 1 else 0)
  local y = (if keys.up then 1 else 0) - (if keys.down then 1 else 0)
  local z = (if keys.backward then 1 else 0) - (if keys.forward then 1 else 0)
  if x == 0 and y == 0 and z == 0 then
    return state
  end
  local speed = if keys.sprint then speeds.sprintSpeed elseif keys.walk then speeds.walkSpeed else speeds.speed
  local step = vector.normalize(vector.pack(x, y, z)) * speed * dt
  return table.freeze { position = state.position + head.rotate(state, step), yaw = state.yaw, pitch = state.pitch }
end

-- Moves a shown angle towards its target, covering the fraction `1 - exp(-rate * dt)` of the distance, so the shown
-- view follows a drag smoothly at any frame rate. A rate of zero follows at once.
function head.follow(shown: number, target: number, rate: number, dt: number): number
  if rate <= 0 then
    return target
  end
  return target + (shown - target) * math.exp(-rate * dt)
end

-- The head's orientation as an angle and a unit axis, for `lovr.headset.setPose`.
function head.angleAxis(state: State): (number, number, number, number)
  local cy, sy = math.cos(state.yaw / 2), math.sin(state.yaw / 2)
  local cp, sp = math.cos(state.pitch / 2), math.sin(state.pitch / 2)
  local w, x, y, z = cy * cp, cy * sp, sy * cp, -sy * sp
  local s = math.sqrt(x * x + y * y + z * z)
  if s < 1e-9 then
    return 0, 0, 1, 0
  end
  return 2 * math.atan2(s, w), x / s, y / s, z / s
end

return head
