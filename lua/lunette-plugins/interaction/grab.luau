-- Grab, push, drag, and two-handed scaling for one interaction instance.
--
-- The returned methods close over the instance's pointer registry, its drop
-- emitter, and its pose constraint. No module-global host is shared by
-- separate provider activations.

local vocabulary = require '@lunette-contracts/vocabulary'

local grab = {}

type Surface = vocabulary.Surface
type Pointer = vocabulary.Pointer

export type GrabState = {
  offset: Mat4,
  base: Mat4,
  pushed: number,
  reach: number,
  x: number,
  y: number,
  z: number,
  moving: boolean,
}

-- A two-handed grab: the other pointer holding the same surface, the hands'
-- separation when the second hand took hold, and the surface's width then.
export type Scaling = {
  partner: PointerState,
  separation: number,
  width: number,
}

-- What the grab arithmetic reads and writes of one pointer.
export type PointerState = {
  tuning: vocabulary.Tuning,
  handPosition: { number }?,
  grabbed: Surface?,
  grab: GrabState?,
  scaling: Scaling?,
  dead: boolean,
  pointer: Pointer?,
}

export type Methods = {
  beginGrab: (Pointer, Surface, Mat4?) -> boolean,
  scaleWith: (Pointer, Mat4?) -> (),
  push: (Pointer, number, number) -> (),
  dragTo: (Pointer, Mat4?) -> (),
  endGrab: (Pointer) -> boolean,
}

type Host = {
  read pointers: () -> { PointerState },
  read state: (Pointer) -> PointerState,
  -- Announces that a grab ended, before the pointer forgets the surface.
  read dropped: (Surface, Pointer) -> (),
  -- The pose a carried surface takes for the pose the hand would give it.
  read constrain: (Surface, Mat4) -> Mat4,
}

local function distanceBetween(first: { number }?, second: { number }?): number?
  if not first or not second then
    return nil
  end
  local dx, dy, dz = first[1] - second[1], first[2] - second[2], first[3] - second[3]
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function grabberOf(host: Host, target: Surface, except: Pointer): PointerState?
  for _, state in ipairs(host.pointers()) do
    if state.pointer ~= except and state.grabbed == target then
      return state
    end
  end
  return nil
end

local function ordinaryGrab(target: Surface, handPose: Mat4): GrabState?
  local targetPose = target.pose
  if not targetPose then
    return nil
  end
  local inverse: Mat4 = lovr.math.newMat4(handPose):invert()
  local base: Mat4 = inverse:mul(targetPose)
  local x: number, y: number, z: number = handPose:getPosition()
  return {
    offset = lovr.math.newMat4(base),
    base = base,
    pushed = 0,
    reach = -select(3, base:getPosition()),
    x = x,
    y = y,
    z = z,
    moving = false,
  }
end

local function place(host: Host, target: Surface, pose: Mat4): ()
  local setPose = target.setPose
  if not setPose then
    return
  end
  local constrained = host.constrain(target, pose)
  if constrained == nil then
    error('interaction: constrain answered nothing, not a pose', 0)
  end
  setPose(target, constrained)
end

function grab.new(host: Host): Methods
  local function beginGrab(self: Pointer, target: Surface, handPose: Mat4?): boolean
    local state = host.state(self)
    if not handPose or not target.setPose then
      return false
    end

    local x: number, y: number, z: number = handPose:getPosition()
    state.handPosition = { x, y, z }
    state.grabbed = target

    local partner = grabberOf(host, target, self)
    local separation = partner and distanceBetween({ x, y, z }, partner.handPosition)
    if partner and separation and target.width and separation > 0 then
      state.scaling = { partner = partner, separation = separation, width = target.width }
      return true
    end

    local ordinary = ordinaryGrab(target, handPose)
    if not ordinary then
      state.grabbed = nil
      return false
    end
    state.grab = ordinary
    return true
  end

  local function scaleWith(self: Pointer, handPose: Mat4?): ()
    local state = host.state(self)
    local scaling = state.scaling
    local target = state.grabbed
    if not scaling or not target or not handPose then
      return
    end
    state.handPosition = { handPose:getPosition() }

    local partner = scaling.partner
    if partner.grabbed ~= target or partner.dead then
      state.scaling = nil
      state.grab = ordinaryGrab(target, handPose)
      return
    end

    local separation = distanceBetween(state.handPosition, partner.handPosition)
    if not separation or separation <= 0 then
      return
    end

    local tuning = state.tuning
    local width = scaling.width * (separation / scaling.separation)
    width = math.max(tuning.resizeMinimum, math.min(tuning.resizeMaximum, width))
    if target.setSize then
      target:setSize(width)
    end
    local pose = target.pose
    if pose then
      place(host, target, lovr.math.newMat4(pose))
    end
  end

  local function push(self: Pointer, deflection: number, dt: number): ()
    local state = host.state(self)
    local current = state.grab
    if not current or not current.base or dt <= 0 then
      return
    end

    local tuning = state.tuning
    if math.abs(deflection) < tuning.scrollDeadZone then
      return
    end

    local reachAtGrab = current.reach
    local wanted = current.pushed + deflection * tuning.reachScale * dt
    local reach = math.max(tuning.reachMinimum, math.min(tuning.reachMaximum, reachAtGrab + wanted))
    local pushed = reach - reachAtGrab
    if pushed == current.pushed then
      return
    end

    current.pushed = pushed
    current.offset:set(lovr.math.newMat4():translate(0, 0, -pushed):mul(current.base))
    current.moving = true
  end

  local function dragTo(self: Pointer, handPose: Mat4?): ()
    local state = host.state(self)
    local current = state.grab
    if not handPose or not current then
      return
    end

    local x: number, y: number, z: number = handPose:getPosition()
    state.handPosition = { x, y, z }
    if not current.moving then
      local dx, dy, dz = x - current.x, y - current.y, z - current.z
      if dx * dx + dy * dy + dz * dz <= state.tuning.grabDeadZone ^ 2 then
        return
      end
      current.moving = true
    end

    local target = state.grabbed
    if not target then
      return
    end
    place(host, target, lovr.math.newMat4():set(handPose):mul(current.offset))
  end

  -- Answers whether the pointer was carrying a surface. The drop is
  -- announced while the pointer still names the surface as grabbed, so a
  -- listener that asks the pointer sees what it let go of.
  local function endGrab(self: Pointer): boolean
    local state = host.state(self)
    local target = state.grabbed
    if not target then
      state.grab, state.scaling = nil, nil
      return false
    end
    local ok, failure = pcall(host.dropped, target, self)
    state.grabbed, state.grab, state.scaling = nil, nil, nil
    if not ok then
      error(failure, 0)
    end
    return true
  end

  return {
    beginGrab = beginGrab,
    scaleWith = scaleWith,
    push = push,
    dragTo = dragTo,
    endGrab = endGrab,
  }
end

return grab
