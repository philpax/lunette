-- Carrying a surface: taking hold of one, moving it with the hand, pushing it
-- along the ray, sizing it between two hands, and letting go.
--
-- The interaction module has two halves. `mullion.interaction` tracks what a
-- pointer is over and where its input goes. This module is the arithmetic of a
-- hand holding something, and the feel of a grab is the tuning applied to it.
--
-- Each function takes the pointer as its first argument. `mullion.interaction`
-- installs them as methods on a pointer. They are written against
-- `mullion.interaction.types`. None of them names a live pointer, and the
-- grab module holds no state of its own.

local pointing = require '@mullion/interaction/types'
local signal = require '@mullion/signal'

local grab = {}

type Pointer = pointing.Pointer
type Surface = pointing.Surface

-- Every live pointer, as `mullion.interaction` provides them. The caller
-- passes them in, because the list is `mullion.interaction`'s state and the
-- grab module holds none.
export type Pointers = () -> { Pointer }

-- What `install` is given: the pointer registry and the pose store, both owned
-- by `mullion.interaction`.
export type Host = {
  read pointers: Pointers,
  read storePose: (Surface) -> boolean,
}

local host: Host

-- Declared above the public functions and defined below them. The public API
-- comes first.
local grabberOf: (Surface, Pointer) -> Pointer?
local distanceBetween: ({ number }?, { number }?) -> number?

-- Takes the module's own state and returns the functions to install as
-- methods. Called once, from `mullion.interaction`.
function grab.install(given: Host)
  host = given
  return {
    beginGrab = grab.beginGrab,
    scaleWith = grab.scaleWith,
    push = grab.push,
    dragTo = grab.dragTo,
    endGrab = grab.endGrab,
  }
end

-- Takes hold of a panel and records the hand's position relative to it.
--
-- The offset keeps the panel's position and orientation relative to the hand.
-- A panel grabbed from two metres away stays two metres away; it does not snap
-- to the hand.
function grab.beginGrab(self: Pointer, target: Surface, handPose: Mat4?): boolean
  if not handPose or not target.setPose then
    return false
  end

  local x: number, y: number, z: number = handPose:getPosition()
  self.grabbed = target

  -- A panel already held by the other hand stays with that hand. This grab
  -- measures the separation for a resize.
  local partner = grabberOf(target, self)
  local separation = partner and distanceBetween({ x, y, z }, partner.handPosition)
  if partner and separation and target.width and separation > 0 then
    self.scaling = { partner = partner, separation = separation, width = target.width }
    signal.emit(target, 'grabbed', self)
    return true
  end

  local targetPose = target.pose
  if not targetPose then
    -- The scaling branch keeps `grabbed` set, so the assignment precedes it. A refusal
    -- clears it: `update` returns early on a pointer that holds something, so a grab
    -- that never began would suppress hover, pick, and click until the grip is released.
    self.grabbed = nil
    return false
  end
  local inverse: Mat4 = lovr.math.newMat4(handPose):invert()
  local base: Mat4 = inverse:mul(targetPose)
  self.grab = {
    -- The inverse of the hand's pose times the panel's pose. Apply the hand's new pose
    -- to it and the panel arrives where the hand has taken it.
    offset = lovr.math.newMat4(base),
    -- The same value as the offset, and it stays unchanged. Each push rebuilds
    -- the offset from this copy, so the pushed distance stays a single value
    -- and the clamp cannot move the panel on its own.
    base = base,
    -- How far the stick has moved the panel from its pickup position, and how far away
    -- the panel is at the start.
    pushed = 0,
    reach = -select(3, base:getPosition()),
    x = x,
    y = y,
    z = z,
    moving = false,
  }
  signal.emit(target, 'grabbed', self)
  return true
end

-- The pointer other than `except` holding `target`, if there is one.
function grabberOf(target: Surface, except: Pointer): Pointer?
  for _, pointer in ipairs(host.pointers()) do
    if pointer ~= except and pointer.grabbed == target then
      return pointer
    end
  end
  return nil
end

-- The distance between two positions, or nil when either is missing.
function distanceBetween(a: { number }?, b: { number }?): number?
  if not a or not b then
    return nil
  end
  local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Sizes the grabbed panel by how far apart the two hands holding it are.
--
-- The ratio is against the separation when the second hand closes, so the panel
-- keeps that size until the hands move apart or together.
function grab.scaleWith(self: Pointer, handPose: Mat4?): ()
  local scaling = self.scaling
  local target = self.grabbed
  if not scaling or not target or not handPose then
    return
  end

  local partner = scaling.partner
  if not partner or partner.grabbed ~= target or partner.dead then
    -- The other hand no longer holds the panel. This hand keeps holding it and
    -- inherits an ordinary grab.
    self.scaling = nil
    local x: number, y: number, z: number = handPose:getPosition()
    local targetPose = target.pose
    if not targetPose then
      return
    end
    local inverse: Mat4 = lovr.math.newMat4(handPose):invert()
    local base: Mat4 = inverse:mul(targetPose)
    self.grab = {
      offset = lovr.math.newMat4(base),
      base = base,
      pushed = 0,
      reach = -select(3, base:getPosition()),
      x = x,
      y = y,
      z = z,
      moving = false,
    }
    return
  end

  local separation = distanceBetween({ handPose:getPosition() }, partner.handPosition)
  if not separation or separation <= 0 then
    return
  end

  local tuning = self.tuning
  local width = scaling.width * (separation / scaling.separation)
  width = math.max(tuning.resizeMinimum, math.min(tuning.resizeMaximum, width))
  if target.setSize then
    target:setSize(width)
  end
end

-- Moves a grabbed panel along the hand's forward axis.
--
-- The stick that scrolls in other contexts pushes the panel while a grab
-- is held. `dragTo` derives the panel pose from the hand's pose and the offset
-- each frame, so a push changes the offset. The new distance then survives
-- the next frame's drag.
function grab.push(self: Pointer, deflection: number, dt: number): ()
  local grab = self.grab
  if not grab or not grab.base or dt <= 0 then
    return
  end

  local tuning = self.tuning
  if math.abs(deflection) < tuning.scrollDeadZone then
    return
  end

  -- Pushing the stick away moves the panel away, and away is -Z in the hand's frame.
  -- The offset applies the pushed distance negated.
  local pushedBefore: number = grab.pushed
  local reachAtGrab: number = grab.reach
  local reachScale: number = tuning.reachScale
  local wanted: number = pushedBefore + deflection * reachScale * dt
  local reach: number = reachAtGrab + wanted
  reach = math.max(tuning.reachMinimum, math.min(tuning.reachMaximum, reach))
  local pushed: number = reach - reachAtGrab
  if pushed == grab.pushed then
    return
  end

  grab.pushed = pushed
  grab.offset:set(lovr.math.newMat4():translate(0, 0, -pushed):mul(grab.base))

  -- The dead zone covers a hand that shakes while the grip goes down. A stick
  -- beyond its own dead zone is a deliberate input, so it starts the grab
  -- moving. The grab does not wait for the hand to travel too.
  grab.moving = true
end

-- Moves the grabbed panel to where the hand has taken it.
--
-- Nothing moves until the hand has left the dead zone, and then everything
-- moves for the rest of the grab. Re-checking each frame would make a slow
-- drag stutter, since a hand crossing a room a millimetre per frame
-- never leaves it.
function grab.dragTo(self: Pointer, handPose: Mat4?): ()
  local grab = self.grab
  if not handPose or not grab then
    return
  end

  local x: number, y: number, z: number = handPose:getPosition()
  local grabX: number, grabY: number, grabZ: number = grab.x, grab.y, grab.z
  local deadZone: number = self.tuning.grabDeadZone
  if not grab.moving then
    local dx: number, dy: number, dz: number = x - grabX, y - grabY, z - grabZ
    if dx * dx + dy * dy + dz * dz <= deadZone ^ 2 then
      return
    end
    grab.moving = true
  end

  local target = self.grabbed
  if not target or not target.setPose then
    return
  end
  target:setPose(lovr.math.newMat4():set(handPose):mul(grab.offset))
end

-- Lets go and records the panel's final pose in the property store.
function grab.endGrab(self: Pointer): boolean
  local target = self.grabbed
  self.grabbed, self.grab, self.scaling = nil, nil, nil
  if not target then
    return false
  end

  signal.emit(target, 'dropped', self)
  if target.dead then
    return false
  end
  return host.storePose(target)
end

return grab
