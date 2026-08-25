-- Interaction: what a pointer is over, what it clicked, and what it is holding.
--
-- docs/stdlib.md's tier 2, minus the device and minus the drawing. A pointer is
-- handed a frame of input and a list of panels and decides what happens: which
-- panel is hovered, which sink the pixel goes to, when a click becomes a focus
-- change, and where a grabbed panel ends up. `mullion.laser` is the shell that
-- reads `lovr.headset`, owns the seat, and draws the beam.
--
-- Hover and focus are separate, as docs/input.md#seats keeps them separate in
-- the compositor. A hover sends `sink:pointer` and takes `sink:leave` off
-- whatever it left; only a click calls `seat:setFocus`. Deriving focus from
-- pointer motion is the heuristic the native layer deliberately does not have,
-- and having it here would make one hand steal the keyboard from the other by
-- pointing.
--
-- Every sink call carries the pointer's own seat as its trailing argument. A
-- pointer that left it off would address the seat the session started with, so
-- two hands would share one cursor and one focus, which is what two seats exist
-- to avoid.

local lunette = require '@lunette'
local types = require '@mullion/interaction/types'
local grab = require '@mullion/interaction/grab'
local pose = require '@mullion/pose'
local signal = require '@mullion/signal'
local teardown = require '@mullion/teardown'

local interaction = {}

local methods = {}
local metatable = { __index = methods }

-- Re-exported from `mullion.interaction.types`, which holds the vocabulary so
-- that a lower tier can name `Surface` without requiring this one. These are
-- the names the rest of the tree and docs/stdlib.md use.
export type Tuning = types.Tuning
export type Input = types.Input
export type Surface = types.Surface
export type Pointer = types.Pointer
export type Grab = types.Grab
export type Scaling = types.Scaling

local applyDeadZone: (number, number) -> number
local remove: (Pointer) -> ()

-- Every live pointer, in creation order. Rebuilt when this file runs, so a soft
-- reload starts with none.
local pointers: { Pointer } = {}

-- The seat and sink of the last click, which is where a keyboard types.
--
-- Module state rather than per-pointer, because a virtual keyboard has one
-- target and the user's answer to "which one" is whichever they last clicked.
-- Both are nil until something has been clicked.
local focusedSeat: lunette.Seat?, focusedSink: lunette.Sink?

-- Everything the feel of a pointer is tuned by, in one table.
interaction.TUNING = {
  -- How far a ray reaches, in metres. A panel further away than this is not
  -- hovered, so a laser does not click through a wall at something behind it.
  reach = 8,
  -- How far the hand moves before a grab starts moving the panel, in metres.
  -- Without it a grab nudges the panel by however much the hand shook while the
  -- grip button went down.
  grabDeadZone = 0.006,
  -- Surface pixels per second at full thumbstick deflection.
  scrollScale = 900,
  -- Deflection below which the stick is treated as centred. A stick at rest
  -- reports a small non-zero value, and a stick that needs a deliberate push is
  -- better than a page scrolling under a resting thumb.
  scrollDeadZone = 0.2,
  -- Metres per second the stick pushes a grabbed panel along the hand's
  -- forward axis. The stick scrolls when nothing is held and moves what is held
  -- when something is; a panel being carried is not one being read, so both
  -- uses never compete for the stick at once.
  reachScale = 1.2,
  -- How near the hand a pushed panel may come, in metres. Closer than this it
  -- is inside the hand holding it.
  reachMinimum = 0.2,
  -- How far a pushed panel may go. Past `reach` it could not be picked up
  -- again, which would lose the window rather than place it.
  reachMaximum = 6,
  -- The narrowest and widest a two-handed resize may take a panel, in metres.
  -- A panel scaled to nothing cannot be grabbed again to undo it, which would
  -- lose the window rather than size it.
  resizeMinimum = 0.15,
  resizeMaximum = 4,
  -- Which pointer button the trigger is.
  button = 'left',
}

-- The property-store key a grabbed panel's pose is written under. Namespaced,
-- because the store is shared with the configuration and with every other
-- library a configuration loads.
--
-- A module constant rather than a tuning field. `storePose` and `restorePose`
-- take a panel and not a pointer, so there is no pointer whose tuning they could
-- ask; a per-pointer key would have been read from the module default whatever a
-- pointer was created with, and a pose written under one key and looked for
-- under another is a hand-placed panel that quietly does not come back.
interaction.POSE_PROPERTY = 'mullion.pose'

-- The nearest panel a ray meets, in the panel's own pixels.
--
-- Answers the panel, the pixel coordinate, and the distance in metres, or
-- nothing. `panels` is anything with a `raycast` and a `dead` field, so a
-- configuration's own object is as pickable as a `mullion.panel`.
--
-- The direction is normalised first. `panel.rayQuadHit` reports the distance in
-- units of the direction it was given, so an unnormalised ray would be compared
-- against the reach in units of itself and a longer vector would see further.
function interaction.pick(
  surfaces: { Surface },
  origin: vector,
  direction: vector,
  tuning: Tuning
): (Surface?, number?, number?, number?)
  tuning = tuning or interaction.TUNING

  -- Scale rather than normalize in place, since the input belongs to the caller.
  local length = direction:length()
  if not (length > 0) then
    return nil, nil, nil, nil
  end
  local ray = direction * (1 / length)

  local hit: Surface?, hitX: number?, hitY: number?, hitDistance: number?
  for _, candidate in ipairs(surfaces) do
    if not candidate.dead then
      local pixelX, pixelY, distance = candidate:raycast(origin, ray)
      if
        pixelX
        and pixelY
        and distance
        and distance <= tuning.reach
        and (not hitDistance or distance < hitDistance)
      then
        hit, hitX, hitY, hitDistance = candidate, pixelX, pixelY, distance
      end
    end
  end
  return hit, hitX, hitY, hitDistance
end

-- A thumbstick deflection as a scroll delta in surface pixels.
--
-- `dt` is the frame's duration in seconds, so the same push scrolls the same
-- distance whether the headset is running at 72Hz or at 120.
--
-- The vertical axis is inverted. A stick pushed away from the user reads as
-- "go up the page", and Wayland's vertical axis grows downwards, so up is a
-- negative delta.
function interaction.scrollDelta(x: number, y: number, dt: number?, tuning: Tuning)
  tuning = tuning or interaction.TUNING
  local scale = tuning.scrollScale * (dt or 0)
  return applyDeadZone(x, tuning.scrollDeadZone) * scale, -applyDeadZone(y, tuning.scrollDeadZone) * scale
end

-- Writes a panel's pose to its window's property store, reporting whether it
-- went.
--
-- A hand-placed pose is not derivable from a rule and must survive reload.
--
-- A panel over a monitor answers false. `lunette` has a per-window store and no
-- per-monitor one, so a mirrored screen's pose has nowhere native to live; that
-- is a gap in the API rather than a decision made here, and until it closes a
-- monitor's arrangement is `mullion.persist`'s to write to disk.
function interaction.storePose(target: Surface): boolean
  if target.dead or target.kind ~= 'window' or not target.pose then
    return false
  end
  local source = target.source
  if source.dead then
    return false
  end
  return source:setProperty(interaction.POSE_PROPERTY, pose.encode(target.pose)) and true
end

-- Puts a panel back where the property store says it was, reporting whether
-- there was anything to go on.
function interaction.restorePose(target: Surface): boolean
  if target.dead or target.kind ~= 'window' then
    return false
  end

  local setPose = target.setPose
  local kept = pose.decode(target.source:getProperty(interaction.POSE_PROPERTY))
  if not kept or not setPose then
    return false
  end
  setPose(target, kept)
  return true
end

-- A pointer over a set of panels.
--
-- `options` takes `seat`, the seat every sink call is addressed to, and
-- `tuning`, defaulting to `interaction.TUNING`.
function interaction.newPointer(options: { seat: lunette.Seat?, tuning: Tuning? }?): Pointer
  options = options or ({} :: { seat: lunette.Seat?, tuning: Tuning? })
  local pointer = {
    seat = options.seat,
    tuning = options.tuning or interaction.TUNING,
    -- What the ray is over, and where on it, in the source's pixels.
    hovered = nil,
    hitX = nil,
    hitY = nil,
    distance = nil,
    -- What the grip is holding, and what it is holding it by.
    grabbed = nil,
    grab = nil,
    gripped = false,
    -- The button, and what it was pressed on: a release goes to whatever took
    -- the press, even when the ray has left it.
    pressed = false,
    pressedSink = nil,
    pressedSurface = nil,
    dead = false,
  } :: Pointer
  setmetatable(pointer, metatable)

  pointers[#pointers + 1] = pointer
  return pointer
end

-- Every live pointer, in creation order, as a fresh table.
function interaction.pointers(): { Pointer }
  local live: { Pointer } = {}
  for _, existing in ipairs(pointers) do
    if not existing.dead then
      live[#live + 1] = existing
    end
  end
  return live
end

-- The seat and sink of the last click, which is where typed text goes.
function interaction.focused(): (lunette.Seat?, lunette.Sink?)
  return focusedSeat, focusedSink
end

-- Records where the keyboard went. Called by a pointer on a click, and by a
-- configuration that focused a sink some other way.
function interaction.setFocus(seat: lunette.Seat?, sink: lunette.Sink?)
  focusedSeat, focusedSink = seat, sink
end

-- Destroys every pointer and forgets the focus.
--
-- Registered as this module's teardown hook.
function interaction.teardown()
  for _, existing in ipairs(interaction.pointers()) do
    existing:destroy()
  end
  pointers = {}
  focusedSeat, focusedSink = nil, nil
end

-- Brings the pointer up to date for one frame.
--
-- `input` carries `origin` and `direction` as `Vec3`s or arrays of three;
-- `pose`, the pointing device's `Mat4`, which is what a grab moves a panel by;
-- `trigger` and `grip`; `scrollX` and `scrollY` as stick deflections in -1 to 1;
-- and `dt`, the frame's duration in seconds.
--
-- `panels` is what the ray may hit. It is passed in rather than taken from
-- `mullion.panel`, so that a configuration can point at a subset (one tag's
-- worth) or at something of its own.
function methods:update(input: Input, panels: { Surface })
  if self.dead then
    return
  end

  -- Kept for the frame, because a second hand grabbing the same panel measures
  -- its separation from this one and needs somewhere to read it from.
  self.handPosition = input.pose and { input.pose:getPosition() } or nil

  local gripped = input.grip and true or false

  -- A grab owns the frame. The ray is wherever the hand happens to be pointing
  -- while it drags, and hovering whatever it swept past would send a stream of
  -- enter and leave events to panels the user is not interacting with.
  if self.grabbed then
    if self.grabbed.dead or not gripped then
      self:endGrab()
    elseif self.scaling then
      -- The other hand carries the panel. This one only says how big it is,
      -- so it neither drags nor pushes while it scales.
      self:scaleWith(input.pose)
    else
      self:push(input.scrollY or 0, input.dt or 0)
      self:dragTo(input.pose)
    end
    self.gripped = gripped
    return
  end

  local hit, x, y, distance = interaction.pick(panels or {}, input.origin, input.direction, self.tuning)
  self:hover(hit)
  self.hitX, self.hitY, self.distance = x, y, distance

  if hit and gripped and not self.gripped and hit.grabbable ~= false then
    if self:beginGrab(hit, input.pose) then
      self.gripped = true
      return
    end
    -- The rising edge is deliberately not recorded, so the next frame tries
    -- again. `beginGrab` refuses only for a hand whose pose has not arrived,
    -- which is transient; consuming the edge would mean no grab could start
    -- until the user released the grip and pressed it again.
  else
    self.gripped = gripped
  end

  local sink = hit and hit.sink and hit:sink() or nil
  if sink and x and y then
    sink:pointer(x, y, self.seat)
    local dx, dy = interaction.scrollDelta(input.scrollX or 0, input.scrollY or 0, input.dt or 0, self.tuning)
    if dx ~= 0 or dy ~= 0 then
      sink:scroll(dx, dy, self.seat)
    end
  elseif hit and hit.onHover then
    -- The coordinates are whatever the surface's own raycast answered in. A
    -- panel answers pixels because that is what a sink takes; a surface that
    -- draws itself answers in whatever frame its geometry is in.
    hit:onHover(x, y, self)
  end

  self:setButton(input.trigger, sink, hit)
end

-- Stops pointing at anything: drops the grab, releases the button, and leaves
-- whatever it was over. The pointer stays usable.
--
-- This is what a hand that stopped being tracked does. A pointer that merely
-- stopped being updated would leave a panel highlighted and, if the trigger was
-- down when the controller was put down, leave a client holding a button that
-- nothing will ever release.
function methods:withdraw()
  if self.grabbed then
    self:endGrab()
  end
  self:setButton(false, nil)
  self:hover(nil)
end

-- Withdraws the pointer and takes it out of the list.
function methods:destroy()
  if self.dead then
    return false
  end

  self.dead = true
  self:withdraw()
  remove(self)
  return true
end

-- Moves the hover to `hit`, which may be nothing.
--
-- The leave goes to the panel being left rather than to the one arrived at, and
-- it is a hover withdrawal and not a focus change: `sink:leave` says the pointer
-- stopped hovering and says nothing about the keyboard.
function methods.hover(self: Pointer, hit: Surface?): ()
  local previous = self.hovered
  if previous == hit then
    return
  end

  if previous then
    signal.setProperty(previous, 'highlighted', false)
    -- Nothing when the panel died between frames, which is the case
    -- CONTRIBUTING.md's rule about handles is about: the client exited and
    -- there is nobody left to tell.
    local sink = previous.sink and previous:sink()
    if sink then
      sink:leave(self.seat)
    end
    -- A surface with no sink is told directly. It has its own idea of what
    -- being pointed at means, and nothing here knows what that is.
    if previous.onLeave then
      previous:onLeave(self)
    end
  end

  self.hovered = hit
  if hit then
    signal.setProperty(hit, 'highlighted', true)
  end
end

-- Presses or releases the button, on a change and not on every frame.
--
-- A release goes to whatever took the press, even when the ray has left it. A
-- release that went to the panel currently under the ray (or nowhere, because
-- the ray is over nothing) would leave the first client holding a button down
-- for the rest of the session.
function methods.setButton(self: Pointer, pressed: boolean, sink: lunette.Sink?, surface: Surface?): ()
  pressed = pressed and true or false
  if pressed == self.pressed then
    return
  end
  self.pressed = pressed

  if pressed then
    if sink then
      self.pressedSink = sink
      sink:button(self.tuning.button, true, self.seat)
      self:focus(sink)
      return
    end

    -- A surface with no sink handles its own press, and is remembered so that
    -- the release reaches the same one even if the ray has moved off it.
    if surface and surface.onPress then
      self.pressedSurface = surface
      surface:onPress(self.hitX, self.hitY, self)
    end
    return
  end

  local target = self.pressedSink
  self.pressedSink = nil
  if target then
    target:button(self.tuning.button, false, self.seat)
  end

  local released = self.pressedSurface
  self.pressedSurface = nil
  if released and released.onRelease then
    released:onRelease(self)
  end
end

-- Gives this pointer's seat to `sink`, and records it as where typing goes.
function methods:focus(sink: lunette.Sink?)
  if self.seat then
    self.seat:setFocus(sink)
  end
  interaction.setFocus(self.seat, sink)
end

-- A stick deflection with its dead zone removed, rescaled so that the first
-- movement past the zone is a small one rather than a jump to the zone's width.
function applyDeadZone(value: number, dead: number): number
  if type(value) ~= 'number' or value ~= value then
    return 0
  end
  if not (dead < 1) then
    return 0
  end

  local magnitude = math.abs(value)
  if magnitude <= dead then
    return 0
  end
  local sign = value < 0 and -1 or 1
  return sign * (magnitude - dead) / (1 - dead)
end

-- Takes a pointer out of the list, so that a long session does not accumulate
-- dead entries.
function remove(destroyed: Pointer)
  for index = 1, #pointers do
    if pointers[index] == destroyed then
      table.remove(pointers, index)
      return
    end
  end
end

-- The carrying half, installed as methods on a pointer. It is handed the
-- registry and the pose store rather than reaching for either, so the state
-- stays here.
local carrying = grab.install { pointers = interaction.pointers, storePose = interaction.storePose }
methods.beginGrab = carrying.beginGrab
methods.scaleWith = carrying.scaleWith
methods.push = carrying.push
methods.dragTo = carrying.dragTo
methods.endGrab = carrying.endGrab

-- Registered by name so repeated module loading leaves one hook.
teardown.register('mullion.interaction', interaction.teardown)

return interaction
