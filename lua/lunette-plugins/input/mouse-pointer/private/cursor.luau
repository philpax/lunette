-- The cursor's aim as yaw and pitch offsets from the head's forward direction, moved by mouse pixels and held inside a
-- cone around that direction.

local cursor = {}

-- Yaw turns right and pitch turns up, both in radians.
export type Aim = {
  read yaw: number,
  read pitch: number,
}

export type Limits = {
  read sensitivity: number,
  -- The largest angle from the forward direction, below a right angle.
  read cone: number,
}

cursor.CENTRE = table.freeze { yaw = 0, pitch = 0 } :: Aim

-- The aim's direction in the head's frame, where -Z is forward, +X right, and +Y up.
function cursor.direction(aim: Aim): vector
  local cosine = math.cos(aim.pitch)
  return vector.pack(math.sin(aim.yaw) * cosine, math.sin(aim.pitch), -math.cos(aim.yaw) * cosine)
end

-- Holds an aim inside the cone. Each offset is first bounded by the cone, which keeps the direction in front of the
-- head, so moving the direction onto the cone's edge keeps the sides it points to.
function cursor.clamp(aim: Aim, cone: number): Aim
  local bounded: Aim = {
    yaw = math.clamp(aim.yaw, -cone, cone),
    pitch = math.clamp(aim.pitch, -cone, cone),
  }
  local x, y, z = vector.unpack(cursor.direction(bounded))
  if math.acos(math.clamp(-z, -1, 1)) <= cone then
    return table.freeze(bounded)
  end
  local scale = math.sin(cone) / math.sqrt(x * x + y * y)
  return table.freeze {
    yaw = math.atan2(x * scale, math.cos(cone)),
    pitch = math.asin(math.clamp(y * scale, -1, 1)),
  }
end

-- Moves an aim by a mouse movement in window pixels, where y grows downward.
function cursor.move(aim: Aim, dx: number, dy: number, limits: Limits): Aim
  return cursor.clamp({
    yaw = aim.yaw + dx * limits.sensitivity,
    pitch = aim.pitch - dy * limits.sensitivity,
  }, limits.cone)
end

-- The view's half-angles in radians, as `lovr.headset.getViewAngles` reports them: each is positive away from the
-- view's centre.
export type View = {
  read left: number,
  read right: number,
  read up: number,
  read down: number,
}

-- The aim through a point of the window, which shows the view: x and y are window pixels with y downward. A point
-- outside the window aims past the view's edge.
function cursor.fromWindow(x: number, y: number, width: number, height: number, view: View): Aim
  local u, v = x / width, y / height
  local tx = -math.tan(view.left) + u * (math.tan(view.right) + math.tan(view.left))
  local ty = math.tan(view.up) - v * (math.tan(view.up) + math.tan(view.down))
  return table.freeze {
    yaw = math.atan(tx),
    pitch = math.atan2(ty, math.sqrt(1 + tx * tx)),
  }
end

-- The ray's pose: the head's position, turned from the head's orientation by the aim, so its -Z axis is the ray.
function cursor.pose(head: Mat4, aim: Aim): Mat4
  return lovr.math.newMat4(head):rotate(-aim.yaw, 0, 1, 0):rotate(aim.pitch, 1, 0, 0)
end

-- The ray's origin and unit direction for a pose from `cursor.pose`.
function cursor.ray(pose: Mat4): (vector, vector)
  local x, y, z = pose:mul(0, 0, -1, 0)
  return vector.pack(pose:getPosition()), vector.normalize(vector.pack(x, y, z))
end

return cursor
