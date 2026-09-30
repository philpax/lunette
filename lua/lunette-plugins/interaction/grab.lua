-- Grab, push, drag, and two-handed scaling for one interaction instance.
--
-- The returned methods close over the instance's pointer registry and pose
-- writer. No module-global host is shared by separate provider activations.

local vocabulary = require '@lunette-contracts/vocabulary'

local grab = {}

type Surface = vocabulary.Surface

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

export type PointerState = {
  tuning: vocabulary.Tuning,
  handPosition: { number }?,
  grabbed: Surface?,
  grab: GrabState?,
  scaling: vocabulary.Scaling?,
  dead: boolean,
  pointer: vocabulary.Pointer?,
}

export type Methods = {
  beginGrab: (vocabulary.Pointer, Surface, Mat4?) -> boolean,
  scaleWith: (vocabulary.Pointer, Mat4?) -> (),
  push: (vocabulary.Pointer, number, number) -> (),
  dragTo: (vocabulary.Pointer, Mat4?) -> (),
  endGrab: (vocabulary.Pointer) -> boolean,
}

type Host = {
  read pointers: () -> { PointerState },
  read state: (vocabulary.Pointer) -> PointerState,
  read storePose: (Surface) -> boolean,
  read emitDropped: (Surface, vocabulary.Pointer) -> (),
}

local function distanceBetween(first: { number }?, second: { number }?): number?
  if not first or not second then
    return nil
  end
  local dx, dy, dz = first[1] - second[1], first[2] - second[2], first[3] - second[3]
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function grabberOf(host: Host, target: Surface, except: vocabulary.Pointer): PointerState?
  for _, pointer in ipairs(host.pointers()) do
    if pointer.pointer ~= except and pointer.grabbed == target then
      return pointer
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

function grab.new(host: Host): Methods
  local function beginGrab(self: vocabulary.Pointer, target: Surface, handPose: Mat4?): boolean
    local state = host.state(self)
    if not handPose or not target.setPose then
      return false
    end

    local x: number, y: number, z: number = handPose:getPosition()
    state.grabbed = target

    local partner = grabberOf(host, target, self)
    local separation = partner and distanceBetween({ x, y, z }, partner.handPosition)
    if partner and partner.pointer and separation and target.width and separation > 0 then
      state.scaling = { partner = partner.pointer, separation = separation, width = target.width }
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

  local function scaleWith(self: vocabulary.Pointer, handPose: Mat4?): ()
    local state = host.state(self)
    local scaling = state.scaling
    local target = state.grabbed
    if not scaling or not target or not handPose then
      return
    end

    local partner = scaling.partner
    if not partner or partner.grabbed ~= target or partner.dead then
      state.scaling = nil
      state.grab = ordinaryGrab(target, handPose)
      return
    end

    local separation = distanceBetween({ handPose:getPosition() }, partner.handPosition)
    if not separation or separation <= 0 then
      return
    end

    local tuning = state.tuning
    local width = scaling.width * (separation / scaling.separation)
    width = math.max(tuning.resizeMinimum, math.min(tuning.resizeMaximum, width))
    if target.setSize then
      target:setSize(width)
    end
  end

  local function push(self: vocabulary.Pointer, deflection: number, dt: number): ()
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

  local function dragTo(self: vocabulary.Pointer, handPose: Mat4?): ()
    local state = host.state(self)
    local current = state.grab
    if not handPose or not current then
      return
    end

    local x: number, y: number, z: number = handPose:getPosition()
    if not current.moving then
      local dx, dy, dz = x - current.x, y - current.y, z - current.z
      if dx * dx + dy * dy + dz * dz <= state.tuning.grabDeadZone ^ 2 then
        return
      end
      current.moving = true
    end

    local target = state.grabbed
    if not target or not target.setPose then
      return
    end
    target:setPose(lovr.math.newMat4():set(handPose):mul(current.offset))
  end

  local function endGrab(self: vocabulary.Pointer): boolean
    local state = host.state(self)
    local target = state.grabbed
    state.grabbed, state.grab, state.scaling = nil, nil, nil
    if not target then
      return false
    end
    host.emitDropped(target, self)
    if target.dead then
      return false
    end
    return host.storePose(target)
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
