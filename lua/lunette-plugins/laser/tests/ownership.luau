local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local laserContract = require '@lunette-contracts/laser'
local interactionContract = require '@lunette-contracts/interaction'

local test = testing.suite()

local function noInput()
  return nil
end

local function start()
  local env = { native = testing.native() }
  env.session = testing.start { 'drops', 'focus', 'interaction', 'laser' }
  env.consumer = env.session:observe(laserContract.capability)
  env.service, env.owner = env.consumer.service, env.consumer.context
  env.interaction = env.session:observe(interactionContract.capability).service
  return env
end

local function borrowedSeat()
  local seat = { dead = false }
  function seat:setFocus()
    return true
  end
  function seat:destroy()
    self.dead = true
    return true
  end
  return seat
end

test('a hand has one laser, which forHand finds and attach answers to its own owner', function()
  local env = start()
  local seat = borrowedSeat()
  local borrowed = env.service:new(env.owner, 'left', { seat = seat, readInput = noInput })
  expect.equal(borrowed.seat, seat, 'the borrowed seat')
  expect.falsy(borrowed.ownsSeat, 'a borrowed seat is not owned')

  local attached = env.service:attach(env.owner, { readInput = noInput })
  expect.equal(#attached, 2, 'the attached lasers')
  expect.equal(attached[1], borrowed, "attach answers the owner's own laser for a hand it holds")
  expect.equal(attached[2].hand, 'right', 'the free hand')
  expect.truthy(attached[2].ownsSeat and attached[2].seat ~= seat, 'the free hand gets a seat of its own')
  expect.equal(env.service:forHand 'left', borrowed, 'forHand')
  expect.equal(#env.interaction:pointers(), 2, 'each laser is a pointer')

  local again = env.service:attach(env.owner)
  expect.truthy(again[1] == attached[1] and again[2] == attached[2], 'attach is idempotent')
  expect.equal(#env.service:all(), 2, 'the lasers after a second attach')

  local rival = env.session:observe(laserContract.capability)
  expect.raises(function()
    env.service:attach(rival.context)
  end, 'another owner holds', 'attach for a hand another owner holds')
  expect.equal(#env.service:all(), 2, 'a refused attach makes nothing')

  local ownedSeat = attached[2].seat
  env.consumer.instance:disable()
  expect.equal(#env.service:all(), 0, 'the lasers after the owner unloads')
  expect.equal(#env.interaction:pointers(), 0, 'the pointers after the owner unloads')
  expect.falsy(seat.dead, 'a borrowed seat outlives the laser')
  expect.truthy(ownedSeat.dead, 'an owned seat ends with the laser')
  env.session:close()
end)

test('a destroyed laser releases its seat and pointer and is not retained', function()
  local env = start()
  local retained = setmetatable({}, { __mode = 'v' })
  do
    local laser = env.service:new(env.owner, 'left', { readInput = noInput })
    local seat = laser.seat
    retained.laser, retained.pointer = laser, laser.pointer
    expect.truthy(laser:destroy(), 'the first destroy')
    expect.truthy(seat.dead, 'the owned seat')
    expect.falsy(laser:destroy(), 'a second destroy')
  end
  testing.collect()
  expect.truthy(retained.laser == nil and retained.pointer == nil, 'the destroyed laser and pointer are collected')
  env.session:close()
end)

test('a laser whose owner unloaded does nothing, and a replacement provider serves the owner again', function()
  local env = start()
  local reads = 0
  local function readInput()
    reads += 1
    return nil
  end
  local seat = borrowedSeat()
  local stale = env.service:new(env.owner, 'right', { seat = seat, readInput = readInput })
  env.consumer.instance:disable()
  expect.falsy(stale:destroy(), 'destroy on a stale laser')
  expect.falsy(stale:vibrate(), 'vibrate on a stale laser')
  stale:update {}
  stale:draw(env.native.events.pass)
  expect.equal(reads, 0, 'a stale laser reads no input')
  expect.equal(#env.native.events.draw, 0, 'a stale laser draws nothing')
  expect.equal(env.native.events.haptics, nil, 'a stale laser pulses nothing')

  local laserInstance = env.session.instances.laser
  local first = env.service
  laserInstance:disable()
  expect.raises(function()
    first:all()
  end, nil, 'the retired service')

  laserInstance:enable()
  env.consumer.instance:enable()
  local replacement = env.consumer.service
  expect.truthy(replacement ~= first, 'the consumer reaches the replacement service')
  replacement:new(env.consumer.context, 'left', { seat = seat, readInput = readInput })
  expect.equal(replacement:forHand('left').seat, seat, 'the replacement serves the borrowed seat')
  laserInstance:disable()
  expect.falsy(seat.dead, 'a borrowed seat outlives the provider')
  env.session:close()
end)

test('a failing laser release quarantines its owner, not the providers', function()
  local env = start()
  local held
  local consumer = env.session:use(plugin.define {
    name = 'release-failure',
    requires = { laser = laserContract.capability },
    init = function(context)
      held = context:require(laserContract.capability):new(context, 'left', { readInput = noInput })
    end,
  })
  local failedReleases = 0
  local brokenSink = { dead = false, domain = 'window', id = 404 }
  function brokenSink:button(_, pressed)
    if not pressed then
      failedReleases += 1
      error 'native laser release failed'
    end
  end
  held.pointer:setButton { pressed = true, sink = brokenSink }

  consumer:disable()
  expect.truthy(failedReleases == 1 and held.dead, 'the release ran once')
  expect.equal(consumer:state(), 'quarantined', 'the failing owner')
  expect.equal(env.session.instances.laser:state(), 'active', 'the laser provider')
  expect.equal(env.session.instances.interaction:state(), 'active', 'the interaction provider')
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the reported failures')
  expect.truthy(reports[1]:find('native laser release failed', 1, true), 'the reported failure')

  local replacement = env.service:new(env.owner, 'left', { readInput = noInput })
  expect.falsy(replacement.dead, 'the providers serve another owner')
  env.session:close()
end)

return test
