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

-- Turns the head by a drag in window pixels, where y grows downward: a drag right turns right and a drag down looks
-- down. Pitch stops at straight up and straight down.
function head.look(state: State, dx: number, dy: number, sensitivity: number): State
  return table.freeze {
    position = state.position,
    yaw = state.yaw - dx * sensitivity,
    pitch = math.clamp(state.pitch - dy * sensitivity, -LIMIT, LIMIT),
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
