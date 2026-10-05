-- Implements grab state for one interaction provider activation.
local vocabulary = require '@lunette-contracts/vocabulary'

local grab = {}

type Surface = vocabulary.Surface
type Pointer = vocabulary.Pointer

export type GrabState = {
  offset: Mat4,
  base: Mat4,
  pushed: number,
  reach: number,
  origin: vector,
  moving: boolean,
}

-- The second pointer scales the surface from its initial hand separation and width.
export type Scaling = {
  partner: PointerState,
  separation: number,
  width: number,
}

export type PointerState = {
  tuning: vocabulary.Tuning,
  handPosition: vector?,
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
  detachGrab: (PointerState, Pointer) -> (() -> ())?,
}

type GrabIdentity = { announced: boolean }

type Host = {
  read pointers: () -> { PointerState },
  read state: (Pointer) -> PointerState,
  -- Announces a drop before the pointer clears its grabbed surface.
  read dropped: (Surface, Pointer) -> (),
  read constrain: (Surface, Mat4) -> Mat4,
  read current: (Pointer) -> () -> boolean,
}

local function distanceBetween(first: vector?, second: vector?): number?
  if not first or not second then
    return nil
  end
  return (first - second):length()
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
  return {
    offset = lovr.math.newMat4(base),
    base = base,
    pushed = 0,
    reach = -select(3, base:getPosition()),
    origin = vector.pack(handPose:getPosition()),
    moving = false,
  }
end

local function place(host: Host, target: Surface, pose: Mat4, current: () -> boolean): ()
  local setPose = target.setPose
  if not setPose or target.dead or not current() then
    return
  end
  local constrained = host.constrain(target, pose)
  if not current() or target.dead then
    return
  end
  if constrained == nil then
    error('interaction: constrain answered nothing, not a pose', 0)
  end
  setPose(target, constrained)
end

function grab.new(host: Host): Methods
  local identities: { [Pointer]: GrabIdentity } = {}

  local function announce(identity: GrabIdentity, target: Surface, pointer: Pointer): ()
    if not identity.announced then
      identity.announced = true
      host.dropped(target, pointer)
    end
  end

  local function detachGrab(state: PointerState, pointer: Pointer): (() -> ())?
    local target, identity = state.grabbed, identities[pointer]
    state.grabbed, state.grab, state.scaling = nil, nil, nil
    identities[pointer] = nil
    if not target or not identity or identity.announced then
      return nil
    end
    return function()
      announce(identity, target, pointer)
    end
  end

  local function beginGrab(self: Pointer, target: Surface, handPose: Mat4?): boolean
    local state = host.state(self)
    local current = host.current(self)
    if not current() or target.dead or not handPose or not target.setPose then
      return false
    end

    local position = vector.pack(handPose:getPosition())
    if not current() then
      return false
    end
    state.handPosition = position
    state.grabbed = target

    local partner = grabberOf(host, target, self)
    local separation = partner and distanceBetween(position, partner.handPosition)
    if partner and separation and target.width and separation > 0 then
      state.scaling = { partner = partner, separation = separation, width = target.width }
      identities[self] = { announced = false }
      return true
    end

    local ordinary = ordinaryGrab(target, handPose)
    if not ordinary then
      state.grabbed = nil
      identities[self] = nil
      return false
    end
    state.grab = ordinary
    identities[self] = { announced = false }
    return true
  end

  local function scaleWith(self: Pointer, handPose: Mat4?): ()
    local state = host.state(self)
    local current = host.current(self)
    local scaling = state.scaling
    local target = state.grabbed
    if not scaling or not target or not handPose then
      return
    end
    local position = vector.pack(handPose:getPosition())
    if not current() or target.dead then
      return
    end
    state.handPosition = position

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
    if not current() or target.dead then
      return
    end
    local pose = target.pose
    if pose then
      place(host, target, lovr.math.newMat4(pose), current)
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
    local valid = host.current(self)
    local current = state.grab
    if not valid() or not handPose or not current then
      return
    end

    local position = vector.pack(handPose:getPosition())
    if not valid() then
      return
    end
    state.handPosition = position
    if not current.moving then
      local displacement = position - current.origin
      if displacement:dot(displacement) <= state.tuning.grabDeadZone ^ 2 then
        return
      end
      current.moving = true
    end

    local target = state.grabbed
    if not target then
      return
    end
    place(host, target, lovr.math.newMat4():set(handPose):mul(current.offset), valid)
  end

  -- Announces the drop before clearing `grabbed`, so listeners can inspect the carried surface.
  local function endGrab(self: Pointer): boolean
    local state = host.state(self)
    local target, identity = state.grabbed, identities[self]
    if not target then
      state.grab, state.scaling = nil, nil
      identities[self] = nil
      return false
    end
    if not identity or identity.announced then
      return false
    end
    local ok, failure = pcall(announce, identity, target, self)
    if identities[self] == identity then
      state.grabbed, state.grab, state.scaling = nil, nil, nil
      identities[self] = nil
    end
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
    detachGrab = detachGrab,
  }
end

return grab
