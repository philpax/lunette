-- Covers lua/mullion/laser.lua.
--
-- The device is driven through `options.readInput`, which is the seam the
-- module has for exactly this: `lovr.headset` is switched off in the spec run,
-- and a laser that could only be driven by a real controller would be a laser
-- nothing could check. `laser.headsetInput`, the default that does read the
-- headset, is the part this cannot reach and is a human gate.
--
-- The seats come from `spec.mullion.laser_fixture`, which states why `lunette`
-- is faked. The panels are real, from `spec.mullion.panel.fixture`.

local expect = require 'spec.expect'
local suite = require 'spec.suite'

local interaction = require 'mullion.interaction'
local fixture = require 'spec.mullion.panel.fixture'
local lasers = require 'spec.mullion.laser_fixture'

local spec = suite.new 'mullion.laser'

local laser = lasers.laser
local panel = fixture.panel
local poseAt = fixture.poseAt
local newWindow = fixture.newWindow
local newPass = fixture.newPass
local lastCall = fixture.lastCall
local TOLERANCE = fixture.TOLERANCE

-- A frame of input aimed straight down -z from the origin, with nothing held.
local function looking(options)
  options = options or {}
  return {
    origin = options.origin or { 0, 0, 0 },
    direction = options.direction or { 0, 0, -1 },
    pose = options.pose or poseAt(0, 0, 0),
    trigger = options.trigger or false,
    grip = options.grip or false,
    scrollX = 0,
    scrollY = 0,
    dt = 1,
  }
end

-- A `readInput` answering whatever the case last put in `frame`, so a case can
-- change the input between updates without rebuilding the laser.
local function newDevice(frame)
  local device = { frame = frame, hands = {} }

  function device.read(hand)
    device.hands[#device.hands + 1] = hand
    return device.frame
  end

  return device
end

-- Starts a case with no lasers, no panels, and no pointers left over.
local function fresh()
  lasers.reset()
  fixture.reset()
  interaction.teardown()
end

-- A panel one metre square, two metres ahead.
local function panelAhead()
  local window = newWindow(800, 600)
  local created = panel.fromWindow(window, { pose = poseAt(0, 0, -2), width = 1, height = 1 })
  return created, window
end

spec('a laser is made for a hand there is a device for', function()
  fresh()
  local left = laser.new('left', { readInput = function() end })

  expect.equal(left.device, laser.DEVICES.left, 'the device')
  expect.equal(left.controller, laser.CONTROLLERS.left, 'the controller')
end)

spec('a laser refuses a hand there is no device for', function()
  fresh()

  expect.raises(function()
    laser.new('third', { readInput = function() end })
  end, 'not a hand', 'making a laser for a third hand')
end)

spec('a laser makes a seat named for its hand', function()
  fresh()
  local left = laser.new('left', { readInput = function() end })

  expect.equal(#lasers.seats, 1, 'seats made')
  expect.equal(lasers.seats[1].name, 'mullion.left', 'the seat name')
  expect.equal(left.seat, lasers.seats[1], "the laser's seat")
end)

spec('a laser handed a seat makes none', function()
  fresh()
  local borrowed = { dead = false, destroy = function() end }
  local left = laser.new('left', { seat = borrowed, readInput = function() end })

  expect.equal(#lasers.seats, 0, 'seats made')
  expect.equal(left.seat, borrowed, "the laser's seat")
end)

spec('destroying a laser destroys the seat it made', function()
  fresh()
  local left = laser.new('left', { readInput = function() end })
  left:destroy()

  expect.equal(lasers.seats[1].destroyed, 1, 'destroy calls')
end)

spec('destroying a laser leaves a borrowed seat alone', function()
  fresh()
  local borrowed = { dead = false, destroyed = 0 }
  function borrowed:destroy()
    self.destroyed = self.destroyed + 1
  end

  laser.new('left', { seat = borrowed, readInput = function() end }):destroy()

  expect.equal(borrowed.destroyed, 0, 'destroy calls')
end)

spec('a laser drives its pointer with what it read', function()
  fresh()
  local created, window = panelAhead()
  local device = newDevice(looking())
  local left = laser.new('left', { readInput = device.read })

  left:update { created }

  expect.equal(device.hands[1], 'left', 'the hand the device was read for')
  expect.equal(left.pointer.hovered, created, 'what the pointer is over')
  local call = lastCall(window.sink, 'pointer')
  expect.truthy(call, 'a pointer call')
  expect.equal(call.arguments[3], left.seat, 'the seat the event was addressed to')
end)

spec('a click gives the keyboard to that hand seat', function()
  fresh()
  local created, window = panelAhead()
  local device = newDevice(looking { trigger = true })
  local left = laser.new('left', { readInput = device.read })

  left:update { created }

  expect.equal(left.seat.focused[1], window.sink, 'what the seat was focused on')
end)

spec('a hand that stops being tracked stops pointing', function()
  fresh()
  local created, window = panelAhead()
  local device = newDevice(looking())
  local left = laser.new('left', { readInput = device.read })

  left:update { created }
  device.frame = nil
  left:update { created }

  expect.falsy(left.pointer.hovered, 'what the pointer is over')
  expect.falsy(created.highlighted, 'the highlight')
  expect.equal(fixture.sequence(window.sink), 'pointer,leave', 'what the sink was told')
end)

spec('a beam stops at a surface that is not a panel', function()
  -- A wrist button and a keyboard are surfaces rather than panels, and the
  -- pointer picks across all of them, so the beam stops on one without the
  -- configuration reporting anything.
  fresh()
  local device = newDevice(looking())
  local left = laser.new('left', { readInput = device.read })
  local pass = newPass()

  -- The smallest thing that satisfies the surface contract.
  local surface = {
    raycast = function()
      return 0, 0, 0.4
    end,
  }

  left:update { surface }
  left:draw(pass)

  expect.equal(#pass.lines, 1, 'lines drawn')
  expect.near(pass.lines[1][6], -0.4, TOLERANCE, "the beam's far z")
end)

spec('a laser draws its beam to the reach when it meets nothing', function()
  fresh()
  local device = newDevice(looking())
  local left = laser.new('left', { readInput = device.read })
  local pass = newPass()

  left:update {}
  left:draw(pass)

  expect.equal(#pass.lines, 1, 'lines drawn')
  expect.equal(#pass.spheres, 0, 'cursors drawn')
  local line = pass.lines[1]
  expect.near(line[6], -laser.STYLE.length, TOLERANCE, "the beam's far z")
end)

spec('a laser draws its beam to the panel it meets', function()
  fresh()
  local created = panelAhead()
  local device = newDevice(looking())
  local left = laser.new('left', { readInput = device.read })
  local pass = newPass()

  left:update { created }
  left:draw(pass)

  local line = pass.lines[1]
  expect.near(line[6], -2, TOLERANCE, "the beam's far z")
  expect.equal(#pass.spheres, 1, 'cursors drawn')
  expect.near(pass.spheres[1][3], -2, TOLERANCE, "the cursor's z")
end)

spec('a laser draws nothing before its first update', function()
  fresh()
  local left = laser.new('left', { readInput = function() end })
  local pass = newPass()

  left:draw(pass)

  expect.equal(#pass.lines, 0, 'lines drawn')
end)

spec('a laser draws nothing while the hand is untracked', function()
  fresh()
  local device = newDevice(nil)
  local left = laser.new('left', { readInput = device.read })
  local pass = newPass()

  left:update {}
  left:draw(pass)

  expect.equal(#pass.lines, 0, 'lines drawn')
end)

spec('attach makes one laser per hand', function()
  fresh()
  local attached = laser.attach { readInput = function() end }

  expect.equal(#attached, 2, 'lasers attached')
  expect.equal(attached[1].hand, 'left', 'the first hand')
  expect.equal(attached[2].hand, 'right', 'the second hand')
  expect.equal(#lasers.seats, 2, 'seats made')
end)

spec('attaching twice does not make a second laser per hand', function()
  fresh()
  laser.attach { readInput = function() end }
  laser.attach { readInput = function() end }

  expect.equal(#laser.all(), 2, 'lasers')
  expect.equal(#lasers.seats, 2, 'seats made')
end)

spec('teardown destroys every laser and its seat', function()
  fresh()
  laser.attach { readInput = function() end }

  laser.teardown()

  expect.equal(#laser.all(), 0, 'lasers left')
  expect.equal(#interaction.pointers(), 0, 'pointers left')
  expect.equal(lasers.seats[1].destroyed, 1, "the first seat's destroy calls")
  expect.equal(lasers.seats[2].destroyed, 1, "the second seat's destroy calls")
end)

spec('the module-wide update and draw reach every laser', function()
  fresh()
  local created = panelAhead()
  local left = laser.new('left', { readInput = newDevice(looking()).read })
  local right = laser.new('right', { readInput = newDevice(looking()).read })
  local pass = newPass()

  laser.update { created }
  laser.draw(pass)

  expect.equal(left.pointer.hovered, created, "the left pointer's panel")
  expect.equal(right.pointer.hovered, created, "the right pointer's panel")
  expect.equal(#pass.lines, 2, 'lines drawn')
end)

spec('requiring the module twice leaves one teardown hook', function()
  fresh()
  local teardown = require 'mullion.teardown'

  local function hooks()
    local found = 0
    for _, name in ipairs(teardown.pending()) do
      if name == 'mullion.laser' then
        found = found + 1
      end
    end
    return found
  end

  -- Through the fixture's fake `lunette`, since the module body requires it.
  local function reload()
    local previous = package.loaded.lunette
    package.loaded.lunette = { newSeat = function() end }
    package.loaded['mullion.laser'] = nil
    local loaded = require 'mullion.laser'
    package.loaded.lunette = previous
    package.loaded['mullion.laser'] = laser
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
