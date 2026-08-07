-- Covers lua/mullion/interaction.lua.
--
-- The panels are real ones, from `spec.mullion.panel.fixture`: the module under
-- test raycasts through `panel:raycast` and moves panels through
-- `panel:setPose`, and a hand-written stand-in for those would be asserting the
-- stand-in's arithmetic rather than the panel's. The sinks and the seat are
-- fakes, because they are the native surface and this process has no client to
-- deliver to.
--
-- Nothing here touches `lovr.headset`. That is the point of the split:
-- everything that decides is in this module, and `mullion.laser` is the shell
-- that reads the device.

local expect = require 'spec.expect'
local suite = require 'spec.suite'

local interaction = require 'mullion.interaction'
local pose = require 'mullion.pose'
local fixture = require 'spec.mullion.panel.fixture'

local spec = suite.new 'mullion.interaction'

local panel = fixture.panel
local poseAt = fixture.poseAt
local newWindow = fixture.newWindow
local sequence = fixture.sequence
local lastCall = fixture.lastCall
local TOLERANCE = fixture.TOLERANCE

-- A seat that records the sinks it was focused on.
--
-- The sinks and the window come from `spec.mullion.panel.fixture`, which holds
-- the fakes the panel, interaction, and laser specs share.
local function newSeat()
  return {
    focused = {},
    setFocus = function(self, sink)
      self.focused[#self.focused + 1] = sink
      return true
    end,
  }
end

-- A frame of input aimed straight down -z from the origin, with nothing held.
local function looking(options)
  options = options or {}
  return {
    origin = options.origin or { 0, 0, 0 },
    direction = options.direction or { 0, 0, -1 },
    pose = options.pose or poseAt(0, 0, 0),
    trigger = options.trigger or false,
    grip = options.grip or false,
    scrollX = options.scrollX or 0,
    scrollY = options.scrollY or 0,
    dt = options.dt or 1,
  }
end

-- Starts a case with no panels, no pointers, and no focus left over.
local function fresh()
  fixture.reset()
  interaction.teardown()
end

-- A panel one metre square, two metres ahead, over a window of the given size.
local function panelAhead(width, height)
  local window = newWindow(width or 800, height or 600)
  local created = panel.fromWindow(window, { pose = poseAt(0, 0, -2), width = 1, height = 1 })
  return created, window
end

spec('pick answers the nearest panel the ray meets', function()
  fresh()
  local near = panelAhead()
  local far = panelAhead()
  far:setPose(poseAt(0, 0, -4))

  local hit, x, y, distance = interaction.pick({ far, near }, { 0, 0, 0 }, { 0, 0, -1 })

  expect.equal(hit, near, 'the panel')
  expect.near(x, 400, TOLERANCE, 'x')
  expect.near(y, 300, TOLERANCE, 'y')
  expect.near(distance, 2, TOLERANCE, 'distance')
end)

spec('pick answers nothing when the ray meets none of them', function()
  fresh()
  local created = panelAhead()

  expect.falsy(interaction.pick({ created }, { 0, 0, 0 }, { 0, 1, 0 }), 'the panel')
end)

spec('pick ignores a panel further away than the reach', function()
  fresh()
  local created = panelAhead()
  created:setPose(poseAt(0, 0, -20))

  expect.falsy(interaction.pick({ created }, { 0, 0, 0 }, { 0, 0, -1 }), 'the panel')
end)

spec('pick over no panels at all answers nothing', function()
  fresh()

  expect.falsy(interaction.pick({}, { 0, 0, 0 }, { 0, 0, -1 }), 'the panel')
end)

spec('a deflection inside the dead zone scrolls nothing', function()
  fresh()
  local dx, dy = interaction.scrollDelta(interaction.TUNING.scrollDeadZone / 2, 0, 1)

  expect.equal(dx, 0, 'dx')
  expect.equal(dy, 0, 'dy')
end)

spec('a forward deflection scrolls the content up', function()
  fresh()
  -- Wayland's vertical axis grows downwards, so pushing the stick away from the
  -- user — which a user reads as "go up the page" — is a negative delta.
  local _, dy = interaction.scrollDelta(0, 1, 1)

  expect.truthy(dy < 0, 'dy')
end)

spec('scroll scales with the time the frame took', function()
  fresh()
  local _, slow = interaction.scrollDelta(0, 1, 1)
  local _, fast = interaction.scrollDelta(0, 1, 0.5)

  expect.near(slow, fast * 2, TOLERANCE, 'the ratio')
end)

spec('hovering points the sink at the pixel under the ray', function()
  fresh()
  local created, window = panelAhead()
  local seat = newSeat()
  local pointer = interaction.newPointer { seat = seat }

  pointer:update(looking(), { created })

  local call = lastCall(window.sink, 'pointer')
  expect.truthy(call, 'a pointer call')
  expect.near(call.arguments[1], 400, TOLERANCE, 'x')
  expect.near(call.arguments[2], 300, TOLERANCE, 'y')
  expect.equal(call.arguments[3], seat, 'the seat the event was addressed to')
  expect.truthy(created.highlighted, 'the highlight')
end)

spec('hovering does not take the keyboard', function()
  fresh()
  local created, window = panelAhead()
  local seat = newSeat()
  local pointer = interaction.newPointer { seat = seat }

  pointer:update(looking(), { created })

  expect.equal(#seat.focused, 0, 'focus changes')
  expect.equal(sequence(window.sink), 'pointer', 'what the sink was told')
end)

spec('leaving a panel withdraws the pointer from it', function()
  fresh()
  local created, window = panelAhead()
  local pointer = interaction.newPointer { seat = newSeat() }

  pointer:update(looking(), { created })
  pointer:update(looking { direction = { 0, 1, 0 } }, { created })

  expect.equal(sequence(window.sink), 'pointer,leave', 'what the sink was told')
  expect.falsy(created.highlighted, 'the highlight')
end)

spec('moving between panels leaves the first before entering the second', function()
  fresh()
  local left, leftWindow = panelAhead()
  local right, rightWindow = panelAhead()
  left:setPose(poseAt(-1, 0, -2))
  right:setPose(poseAt(1, 0, -2))
  local pointer = interaction.newPointer { seat = newSeat() }

  pointer:update(looking { direction = { -1, 0, -2 } }, { left, right })
  pointer:update(looking { direction = { 1, 0, -2 } }, { left, right })

  expect.equal(sequence(leftWindow.sink), 'pointer,leave', 'the panel left behind')
  expect.equal(sequence(rightWindow.sink), 'pointer', 'the panel arrived at')
  expect.falsy(left.highlighted, "the first panel's highlight")
  expect.truthy(right.highlighted, "the second panel's highlight")
end)

spec('a trigger press clicks and takes the keyboard', function()
  fresh()
  local created, window = panelAhead()
  local seat = newSeat()
  local pointer = interaction.newPointer { seat = seat }

  pointer:update(looking { trigger = true }, { created })

  local call = lastCall(window.sink, 'button')
  expect.truthy(call, 'a button call')
  expect.equal(call.arguments[1], interaction.TUNING.button, 'the button')
  expect.equal(call.arguments[2], true, 'pressed')
  expect.equal(call.arguments[3], seat, 'the seat the event was addressed to')
  expect.equal(seat.focused[1], window.sink, 'what the seat was focused on')
end)

spec('a trigger held down does not click again', function()
  fresh()
  local created, window = panelAhead()
  local pointer = interaction.newPointer { seat = newSeat() }

  pointer:update(looking { trigger = true }, { created })
  pointer:update(looking { trigger = true }, { created })
  pointer:update(looking { trigger = true }, { created })

  local presses = 0
  for _, call in ipairs(window.sink.calls) do
    if call.name == 'button' then
      presses = presses + 1
    end
  end
  expect.equal(presses, 1, 'button calls')
end)

spec('a trigger released off the panel still releases on it', function()
  fresh()
  local created, window = panelAhead()
  local pointer = interaction.newPointer { seat = newSeat() }

  pointer:update(looking { trigger = true }, { created })
  -- Off the panel entirely, which is what a hand that slipped during a drag
  -- does. A release that went nowhere would leave the client holding a button
  -- down for the rest of the session.
  pointer:update(looking { direction = { 0, 1, 0 } }, { created })

  local call = lastCall(window.sink, 'button')
  expect.equal(call.arguments[2], false, 'released')
end)

spec('scrolling a hovered panel reaches its sink', function()
  fresh()
  local created, window = panelAhead()
  local seat = newSeat()
  local pointer = interaction.newPointer { seat = seat }

  pointer:update(looking { scrollY = 1 }, { created })

  local call = lastCall(window.sink, 'scroll')
  expect.truthy(call, 'a scroll call')
  expect.truthy(call.arguments[2] < 0, 'dy')
  expect.equal(call.arguments[3], seat, 'the seat the event was addressed to')
end)

spec('a still thumbstick sends no scroll', function()
  fresh()
  local created, window = panelAhead()
  local pointer = interaction.newPointer { seat = newSeat() }

  pointer:update(looking(), { created })

  expect.falsy(lastCall(window.sink, 'scroll'), 'a scroll call')
end)

spec('a grab moves the panel with the hand', function()
  fresh()
  local created = panelAhead()
  local pointer = interaction.newPointer { seat = newSeat() }

  pointer:update(looking { grip = true }, { created })
  pointer:update(looking { grip = true, pose = poseAt(0.5, 0, 0) }, { created })

  local x, y, z = created.pose:getPosition()
  expect.near(x, 0.5, TOLERANCE, 'x')
  expect.near(y, 0, TOLERANCE, 'y')
  expect.near(z, -2, TOLERANCE, 'z')
end)

spec('a grab holds the panel still inside the dead zone', function()
  fresh()
  local created = panelAhead()
  local pointer = interaction.newPointer { seat = newSeat() }

  pointer:update(looking { grip = true }, { created })
  local wobble = interaction.TUNING.grabDeadZone / 2
  pointer:update(looking { grip = true, pose = poseAt(wobble, 0, 0) }, { created })

  local x = created.pose:getPosition()
  expect.near(x, 0, TOLERANCE, 'x')
end)

spec('a grab keeps the offset the hand started with', function()
  fresh()
  local created = panelAhead()
  -- Grabbed from a hand that is not where the panel is, which is every grab: a
  -- pointer that set the pose to the hand's own would teleport the panel into
  -- the hand the moment it was grabbed.
  local pointer = interaction.newPointer { seat = newSeat() }

  pointer:update(looking { grip = true, pose = poseAt(0, 1, 0) }, { created })
  local x, y, z = created.pose:getPosition()
  expect.near(y, 0, TOLERANCE, 'y at the moment of the grab')
  expect.near(z, -2, TOLERANCE, 'z at the moment of the grab')

  pointer:update(looking { grip = true, pose = poseAt(0, 1.5, 0) }, { created })
  x, y, z = created.pose:getPosition()
  expect.near(x, 0, TOLERANCE, 'x')
  expect.near(y, 0.5, TOLERANCE, 'y')
  expect.near(z, -2, TOLERANCE, 'z')
end)

spec('releasing a grab writes the pose to the property store', function()
  fresh()
  local created, window = panelAhead()
  local pointer = interaction.newPointer { seat = newSeat() }

  pointer:update(looking { grip = true }, { created })
  pointer:update(looking { grip = true, pose = poseAt(0.5, 0, 0) }, { created })
  pointer:update(looking(), { created })

  local kept = window.stored[interaction.POSE_PROPERTY]
  expect.truthy(kept, 'what was kept')

  local recovered = pose.decode(kept)
  expect.truthy(recovered, 'the recovered pose')
  local x = recovered:getPosition()
  expect.near(x, 0.5, TOLERANCE, 'the kept x')
end)

spec('a grabbed panel is not clicked as well', function()
  fresh()
  local created, window = panelAhead()
  local pointer = interaction.newPointer { seat = newSeat() }

  pointer:update(looking { grip = true, trigger = true }, { created })

  expect.falsy(lastCall(window.sink, 'button'), 'a button call')
end)

spec('a grip whose pose has not arrived yet grabs on the frame it does', function()
  fresh()
  local created, window = panelAhead()
  local pointer = interaction.newPointer { seat = newSeat() }

  -- A hand tracked well enough to aim but whose pose has not arrived. The grip
  -- is held throughout: an edge consumed by the refusal would mean no grab
  -- could start until the user let go and pressed again.
  local unposed = looking { grip = true }
  unposed.pose = nil
  pointer:update(unposed, { created })

  expect.falsy(pointer.grabbed, 'what is held while the pose is absent')
  -- And the frame is not thrown away: the ray is over the panel, so the panel
  -- hears about it as it would on any other frame.
  expect.truthy(lastCall(window.sink, 'pointer'), 'a pointer call on the refused frame')

  pointer:update(looking { grip = true, pose = poseAt(0, 0, 0) }, { created })

  expect.equal(pointer.grabbed, created, 'what is held once the pose arrives')
end)

spec('the pose property is a module constant rather than a tuning field', function()
  -- `storePose` and `restorePose` take a panel and not a pointer, so a key in
  -- the tuning table would read as per-pointer and be read from the module
  -- default whatever a pointer was created with — and a pose written under one
  -- key and looked for under another is a hand-placed panel that does not come
  -- back.
  expect.falsy(interaction.TUNING.poseProperty, 'a pose property in the tuning table')
  expect.equal(type(interaction.POSE_PROPERTY), 'string', 'the module constant')
end)

spec('a panel that dies mid-grab does not stop the pointer', function()
  fresh()
  local created, window = panelAhead()
  local pointer = interaction.newPointer { seat = newSeat() }

  pointer:update(looking { grip = true }, { created })
  window.dead = true
  created:update()
  pointer:update(looking { grip = true, pose = poseAt(0.5, 0, 0) }, { created })

  expect.falsy(pointer.grabbed, 'what is grabbed')
end)

spec('restorePose puts a panel back where the store says', function()
  fresh()
  local created, window = panelAhead()
  window.stored[interaction.POSE_PROPERTY] =
    pose.encode(lovr.math.newMat4():translate(2, 1, -1))

  expect.truthy(interaction.restorePose(created), 'the restore')
  local x, y, z = created.pose:getPosition()
  expect.near(x, 2, TOLERANCE, 'x')
  expect.near(y, 1, TOLERANCE, 'y')
  expect.near(z, -1, TOLERANCE, 'z')
end)

spec('restorePose leaves a panel alone when the store holds nothing', function()
  fresh()
  local created = panelAhead()

  expect.falsy(interaction.restorePose(created), 'the restore')
  local _, _, z = created.pose:getPosition()
  expect.near(z, -2, TOLERANCE, 'z')
end)

spec('a click records where the keyboard went', function()
  fresh()
  local created, window = panelAhead()
  local seat = newSeat()
  local pointer = interaction.newPointer { seat = seat }

  pointer:update(looking { trigger = true }, { created })

  local focusedSeat, focusedSink = interaction.focused()
  expect.equal(focusedSeat, seat, 'the focused seat')
  expect.equal(focusedSink, window.sink, 'the focused sink')
end)

spec('destroying a pointer withdraws it from what it was hovering', function()
  fresh()
  local created, window = panelAhead()
  local pointer = interaction.newPointer { seat = newSeat() }

  pointer:update(looking(), { created })
  pointer:destroy()

  expect.equal(sequence(window.sink), 'pointer,leave', 'what the sink was told')
  expect.falsy(created.highlighted, 'the highlight')
end)

spec('teardown destroys every pointer', function()
  fresh()
  local created = panelAhead()
  local pointer = interaction.newPointer { seat = newSeat() }
  pointer:update(looking(), { created })

  interaction.teardown()

  expect.equal(#interaction.pointers(), 0, 'the pointers left')
  expect.falsy(created.highlighted, 'the highlight')
  local focusedSeat = interaction.focused()
  expect.falsy(focusedSeat, 'the focused seat')
end)

spec('requiring the module twice leaves one teardown hook', function()
  fresh()
  local teardown = require 'mullion.teardown'

  -- How many hooks this module has registered, counted rather than asserted to
  -- be there: the registry is shared with every other module and with
  -- lua/spec/mullion/teardown_spec.lua, which empties it.
  local function hooks()
    local found = 0
    for _, name in ipairs(teardown.pending()) do
      if name == 'mullion.interaction' then
        found = found + 1
      end
    end
    return found
  end

  local function reload()
    package.loaded['mullion.interaction'] = nil
    local loaded = require 'mullion.interaction'
    package.loaded['mullion.interaction'] = interaction
    return loaded
  end

  local once = reload()
  local first = hooks()
  local twice = reload()
  local second = hooks()

  expect.equal(first, 1, 'hooks after one run of the module body')
  expect.equal(second, 1, 'hooks after two')
  expect.truthy(once, 'the first require')
  expect.truthy(twice, 'the second require')
end)

return spec
