-- Lasers: one pointing device per hand, with a seat of its own.
--
-- docs/stdlib.md's tier 2, the half that touches the outside world. A laser
-- reads a hand's pointer device, owns the seat that hand's input is delivered
-- through, hands a frame of input to a `mullion.interaction` pointer, and draws
-- the beam. Everything that decides what the input means is over there, so that
-- it can be tested without a headset.
--
-- The device is `hand/left/point` rather than `hand/left`. The two are
-- different poses: the second is where the controller is and the first is where
-- the runtime says the user is aiming, which is what every runtime's own
-- pointer uses and what a user expects a laser to follow. The difference is
-- obvious the moment a controller is held at an angle.
--
-- One seat per hand, because a `wl_seat` carries one pointer and one keyboard
-- (docs/input.md#seats). Two hands sharing a seat is WayVR's arrangement, where
-- pointing the off hand at a window takes hover from the main hand; two seats is
-- what makes dragging a slider with one hand while scrolling with the other
-- expressible at all.
--
-- The device is read through `options.readInput`, defaulting to
-- `laser.headsetInput`. That seam is what lets a spec drive a laser through a
-- grab, and it is also how a configuration points at panels with something that
-- is not a hand — a gaze ray, a simulated mouse, a scripted demo.

local lunette = require '@lunette'
local interaction = require '@mullion/interaction'
local teardown = require '@mullion/teardown'

local laser = {}

-- Declared here and defined below the public API, so the file reads
-- surface-first. The metatable is a table rather than a forward-declared local
-- because `new` reads it before the methods below are filled in.
local methods = {}
local metatable = { __index = methods }
local remove

type Hand = 'left' | 'right'
type Device = 'hand/left/point' | 'hand/right/point' | 'hand/left' | 'hand/right'

-- A frame of input from a pointer device, as `readInput` answers it.
type Input = interaction.Input
-- A colour used by the beam and cursor.
type Color = { number }
-- The look of a laser, kept explicit so local style values retain their fields.
type Style = {
  length: number,
  color: Color,
  hoverColor: Color,
  cursorRadius: number,
  hapticStrength: number,
  hapticDuration: number,
}
-- The options `new` and `attach` take.
type LaserOptions = {
  seat: lunette.Seat?,
  name: string?,
  readInput: ((hand: Hand) -> Input?)?,
  tuning: interaction.Tuning?,
  style: Style?,
}
-- The pointer fields this module reads or calls.
type Pointer = interaction.Pointer
-- What a pointer may hit: panels, and whatever else a configuration points at.
type Surface = interaction.Surface

-- A laser instance. The methods use explicit `self: Laser` parameters below so
-- the instance shape does not depend on placeholder values in a prototype.
type Laser = {
  hand: Hand,
  device: Device,
  controller: Device,
  seat: lunette.Seat,
  ownsSeat: boolean,
  readInput: (hand: Hand) -> Input?,
  pointer: Pointer,
  style: Style,
  input: Input?,
  dead: boolean,
  update: (Laser, { Surface }) -> (),
  draw: (Laser, Pass) -> (),
  vibrate: (Laser) -> boolean,
  destroy: (Laser) -> boolean,
}
-- Every live laser, in creation order. Rebuilt when this file runs, so a soft
-- reload starts with none.
local lasers: { Laser } = {}

-- The hands `attach` makes a laser for, in the order it makes them.
laser.HANDS = { 'left', 'right' } :: { Hand }

-- The pointer-ray pose of each hand, which is what a laser follows, and the
-- controller each hand's buttons and axes are read from.
laser.DEVICES = { left = 'hand/left/point', right = 'hand/right/point' } :: { [string]: Device }
laser.CONTROLLERS = { left = 'hand/left', right = 'hand/right' } :: { [string]: Device }

-- Everything the look and the feel of a laser is tuned by, in one table.
--
-- The same reason `mullion.interaction` keeps one: this tier is tuning-heavy,
-- and a tuning pass should be a diff to one table rather than a hunt through
-- functions for a number.
laser.STYLE = {
  -- How far the beam is drawn when it meets nothing, in metres. Shorter than
  -- the pointer's reach on purpose: a beam that ends in mid-air reads as
  -- "pointing at nothing" where one that runs to the horizon reads as a bug.
  length = 1.5,
  color = { 0.55, 0.7, 1, 0.5 },
  -- What the beam takes while it is over something.
  hoverColor = { 0.75, 0.9, 1, 0.9 },
  -- The dot drawn where the beam meets a panel, in metres.
  cursorRadius = 0.006,
  -- The nudge felt when the beam arrives at a panel or leaves one. Short, and
  -- weak: it is an acknowledgement, and a strong one makes sweeping across a
  -- row of panels feel like dragging a stick along a fence.
  hapticStrength = 0.2,
  hapticDuration = 0.01,
}

-- A laser for one hand.
--
-- `options` takes `seat`, a seat to use instead of making one; `name`, what a
-- made seat is called; `readInput`, the device seam; `tuning`, passed to the
-- pointer; and `style`.
function laser.new(hand: Hand, options: LaserOptions?): Laser
  local device = laser.DEVICES[hand]
  if not device then
    error("mullion.laser: '" .. tostring(hand) .. "' is not a hand a laser is made for", 2)
  end
  options = options or ({} :: LaserOptions)

  -- A borrowed seat is not destroyed with the laser: whoever made it decides
  -- when it goes, and a session's first seat refuses to be destroyed at all.
  local seat = options.seat or lunette.newSeat(options.name or ('mullion.' .. hand))

  local created = {
    hand = hand,
    device = device,
    controller = laser.CONTROLLERS[hand],
    seat = seat,
    ownsSeat = options.seat == nil,
    readInput = options.readInput or laser.headsetInput,
    pointer = interaction.newPointer { seat = seat, tuning = options.tuning },
    style = options.style or laser.STYLE,
    -- The last frame's input, kept for `draw`: the beam is drawn where the ray
    -- was when it was tested, and reading the device a second time in the draw
    -- would put the beam somewhere the hit test never happened.
    input = nil,
    dead = false,
  } :: Laser
  setmetatable(created, metatable)

  lasers[#lasers + 1] = created
  return created
end

-- One laser per hand, and the lasers that already existed for hands that have
-- one.
--
-- Safe to call twice, which is what makes it usable from a configuration that
-- is reloaded: a hand that already has a live laser keeps it.
function laser.attach(options: LaserOptions?)
  local attached = {}
  for _, hand in ipairs(laser.HANDS) do
    attached[#attached + 1] = laser.forHand(hand) or laser.new(hand, options)
  end
  return attached
end

-- The live laser for `hand`, or nothing.
function laser.forHand(hand: Hand): Laser?
  for _, existing in ipairs(lasers) do
    if not existing.dead and existing.hand == hand then
      return existing
    end
  end
  return nil
end

-- Every live laser, in creation order, as a fresh table.
function laser.all(): { Laser }
  local live: { Laser } = {}
  for _, existing in ipairs(lasers) do
    if not existing.dead then
      live[#live + 1] = existing
    end
  end
  return live
end

-- Brings every laser up to date against `surfaces`. Called once per frame, from
-- `lovr.update`.
--
-- `surfaces` is passed in rather than taken from `mullion.panel`, so that a
-- configuration can point at one tag's worth, or at objects of its own.
function laser.update(surfaces: { Surface }): ()
  for _, existing in ipairs(laser.all()) do
    existing:update(surfaces)
  end
end

-- Draws every laser.
function laser.draw(pass: Pass)
  for _, existing in ipairs(laser.all()) do
    existing:draw(pass)
  end
end

-- Destroys every laser. Registered as this module's teardown hook, because a
-- reload that left the old state's lasers behind would leave two per hand, each
-- with a seat, each moving panels.
function laser.teardown()
  for _, existing in ipairs(laser.all()) do
    existing:destroy()
  end
  lasers = {}
end

-- A frame of input from `lovr.headset`, or nothing when the hand is not being
-- tracked.
--
-- The default `readInput`, and the one part of this module a spec cannot reach:
-- it is `lovr.headset` and nothing else, so it is a human gate.
function laser.headsetInput(hand: Hand): Input?
  local headset = lovr.headset
  if not headset then
    return nil
  end

  local device = laser.DEVICES[hand]
  local isTracked: (Device) -> boolean = headset.isTracked
  local getPose: (Device) -> (number, number, number, number, number, number, number) = headset.getPose
  local getPosition: (Device) -> (number, number, number) = headset.getPosition
  local getDirection: (Device) -> (number, number, number) = headset.getDirection
  if not isTracked(device) then
    return nil
  end

  local controller = laser.CONTROLLERS[hand]
  local scrollX, scrollY = headset.getAxis(controller, 'thumbstick')
  local poseX, poseY, poseZ, angle, axisX, axisY, axisZ = getPose(device)
  return {
    -- Permanent rather than temporary: a grab keeps the pose it was handed for
    -- the length of the grab, and LÖVR drains its temporaries at the frame
    -- boundary.
    pose = lovr.math.newMat4(poseX, poseY, poseZ, angle, axisX, axisY, axisZ),
    -- `vector.pack` rather than `lovr.math.vec3`: a vector is a value under
    -- Luau, so there is no pool behind either and this is the spelling that says
    -- so. Both device reads answer three numbers, which is what it takes.
    origin = vector.pack(getPosition(device)),
    direction = vector.pack(getDirection(device)),
    trigger = headset.isDown(controller, 'trigger') or false,
    grip = headset.isDown(controller, 'grip') or false,
    scrollX = scrollX or 0,
    scrollY = scrollY or 0,
    dt = headset.getDeltaTime(),
  }
end

-- Reads the device and hands what it read to the pointer.
function methods.update(self: Laser, surfaces: { Surface }): ()
  if self.dead then
    return
  end

  local input: Input? = self.readInput(self.hand)
  self.input = input

  -- A hand that stopped being tracked points at nothing. Withdrawing rather
  -- than leaving the pointer alone is what stops a panel staying highlighted,
  -- and a client holding a button, after a controller is put down.
  if not input then
    self.pointer:withdraw()
    return
  end

  local before = self.pointer.hovered
  self.pointer:update(input, surfaces)
  if self.pointer.hovered ~= before then
    self:vibrate()
  end
end

-- Draws the beam, and a dot where it meets a panel.
--
-- Nothing is drawn before the first update, or while the hand is untracked:
-- there is no ray to draw, and drawing the last one would leave a beam hanging
-- in the air from a controller that has been put down.
function methods.draw(self: Laser, pass: Pass)
  if self.dead then
    return
  end

  local input: Input? = self.input
  if not input then
    return
  end

  local originX, originY, originZ = input.origin:unpack()
  local x, y, z = input.direction:unpack()
  local length = math.sqrt(x * x + y * y + z * z)
  if not (length > 0) then
    return
  end

  local style: Style = self.style
  local hovered = self.pointer.hovered
  local pointerDistance: number? = self.pointer.distance
  local distance: number = style.length
  if hovered and pointerDistance then
    distance = pointerDistance
  end
  local endX = originX + x / length * distance
  local endY = originY + y / length * distance
  local endZ = originZ + z / length * distance

  local color: Color = style.color
  if hovered then
    color = style.hoverColor
  end
  pass:setColor(color[1], color[2], color[3], color[4])

  -- Drawn over whatever it is aimed at. A beam ends on the surface it hit and a
  -- cursor sits in that surface's own plane, so both lose the depth test to the
  -- thing they exist to point at. Depth writing goes with it: a beam that wrote
  -- depth would occlude what is behind it for everything drawn afterwards.
  pass:setDepthTest()
  pass:setDepthWrite(false)

  pass:line(originX, originY, originZ, endX, endY, endZ)
  if hovered then
    pass:sphere(endX, endY, endZ, style.cursorRadius)
  end

  pass:setDepthTest 'lequal'
  pass:setDepthWrite(true)
  pass:setColor(1, 1, 1, 1)
end

-- A short nudge, when the runtime has one to give.
function methods.vibrate(self: Laser): boolean
  local headset = lovr.headset
  if not headset or not headset.vibrate then
    return false
  end
  -- The fourth argument is the haptic frequency in hertz; 0 selects the
  -- device default, which is what a style that does not name one wants.
  return headset.vibrate(self.controller, self.style.hapticStrength, self.style.hapticDuration, 0) and true
end

-- Withdraws the laser: destroys its pointer, destroys the seat it made, and
-- takes itself out of the list.
--
-- A seat it was handed is left alone. Destroying a borrowed seat would withdraw
-- the keyboard from whatever else was using it.
function methods.destroy(self: Laser): boolean
  if self.dead then
    return false
  end

  self.dead = true
  self.pointer:destroy()
  if self.ownsSeat and not self.seat.dead then
    self.seat:destroy()
  end
  remove(self)
  return true
end

-- Takes a laser out of the list, so that a long session does not accumulate
-- dead entries.
function remove(destroyed)
  for index = 1, #lasers do
    if lasers[index] == destroyed then
      table.remove(lasers, index)
      return
    end
  end
end

-- Registered by name, so that a module body running a second time — which is
-- what a soft reload does — leaves one hook rather than two.
--
-- Registered after `mullion.interaction`'s, so it runs before it: a laser has
-- to destroy its pointer while there is still a pointer registry to take it out
-- of.
teardown.register('mullion.laser', laser.teardown)

return laser
