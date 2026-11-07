-- How much of the wrist menu shows as it turns away from the head: fully within the visible angle, not at all past
-- the hidden angle, and easing between the two.

local facing = {}

export type Range = {
  -- Radians from the head within which the menu is fully opaque.
  read visible: number,
  -- Radians from the head past which the menu is transparent.
  read hidden: number,
}

-- The angle in radians between the panel's face, its local +z, and the direction from the panel to the head. A head
-- at the panel's centre counts as facing it.
function facing.angle(pose: Mat4, head: vector): number
  local x, y, z = pose:getPosition()
  local toHead = head - vector.pack(x, y, z)
  local nx, ny, nz = pose:mul(0, 0, 1, 0)
  local normal = vector.pack(nx, ny, nz)
  local lengths = vector.magnitude(toHead) * vector.magnitude(normal)
  if not (lengths > 0) then
    return 0
  end
  return math.acos(math.clamp(vector.dot(toHead, normal) / lengths, -1, 1))
end

-- The opacity for an angle from the head, eased with a smoothstep so the fade has no visible edge.
function facing.opacity(angle: number, range: Range): number
  local t = math.clamp((angle - range.visible) / (range.hidden - range.visible), 0, 1)
  return 1 - t * t * (3 - 2 * t)
end

return facing
