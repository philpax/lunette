local testing = require '@testing'
local expect = testing.expect
local laserContract = require '@lunette-contracts/laser'
local laser = require '@lunette-plugins/laser'
local vrUi = require '@testing/vr-ui'
local interactionContract = require '@lunette-contracts/interaction'

local test = testing.suite()

local function start(definition)
  local env = { native = testing.native() }
  env.controls = vrUi.hands(env.native)
  env.session = testing.start {
    'theme',
    'drops',
    'focus',
    'interaction',
    { id = 'laser', definition = definition or laser.definition },
  }
  env.consumer = env.session:observe(laserContract.capability)
  env.service, env.owner = env.consumer.service, env.consumer.context
  return env
end

local function interaction(env)
  return env.session:observe(interactionContract.capability).service
end

local function trigger(env, held)
  env.controls:button('left', 'trigger', held)
  env.controls:button('right', 'trigger', held)
end

local function calls(env, name)
  local found = {}
  for _, call in ipairs(env.native.events.draw) do
    if call[1] == name then
      found[#found + 1] = call
    end
  end
  return found
end

local function frame(x, y, z)
  return {
    pose = lovr.math.newMat4(),
    origin = vector.create(0, 0, 0),
    direction = vector.create(x, y, z),
    buttons = {},
    grip = false,
    dt = 1 / 60,
  }
end

test("the default reader maps the trigger, and a hover pulses that hand's controller and draws a cursor", function()
  local env = start()
  trigger(env, true)
  local default = env.service:attach(env.owner)[1]
  default:update {}
  expect.equal(default.input.buttons.left, true, 'the default reader maps the trigger to the left button')
  for _, each in env.service:all() do
    each:destroy()
  end
  local inputs = { left = frame(0, 0, -1), right = frame(0, 1, 0) }
  env.service:attach(env.owner, {
    readInput = function(hand)
      return inputs[hand]
    end,
  })
  local style = env.service:forHand('left').style
  env.service:update {}
  env.service:draw(env.native.events.pass)
  expect.equal(#calls(env, 'line'), 2, 'a beam per hand')
  expect.equal(#calls(env, 'sphere'), 0, 'no cursor without a hover')

  local hovers = 0
  local surface = {
    dead = false,
    raycast = function(_, _, direction)
      if direction.y > 0.5 then
        return nil
      end
      return 1, 2, 3
    end,
    onPointer = function(_, event)
      if event.kind == 'enter' then
        hovers += 1
      end
    end,
  }
  env.service:update { surface }
  expect.equal(hovers, 1, 'the hovered surface')
  expect.equal(env.native.events.haptics, 1, 'one pulse')
  expect.equal(env.native.events.haptic.device, 'hand/left', "the pulse reaches the hovering hand's controller")
  expect.equal(env.native.events.haptic.strength, style.hapticStrength, 'the pulse strength')

  table.clear(env.native.events.draw)
  env.service:draw(env.native.events.pass)
  expect.equal(#calls(env, 'sphere'), 1, 'a cursor for the hovering hand')
  env.session:close()
end)

test('the readInput hook wraps the default for every laser, and buttons map the controller', function()
  local read = {}
  local hooked = laser.define {
    name = 'hooked-laser',
    buttons = { { control = 'trigger', button = 'right' } },
    readInput = function(hand, base)
      local result = base(hand)
      read[#read + 1] = { hand = hand, frame = result }
      return result
    end,
  }
  local env = start(hooked)
  trigger(env, true)
  env.service:attach(env.owner)

  env.service:update {}
  expect.truthy(#read == 2 and read[1].hand == 'left' and read[2].hand == 'right', 'the hook saw each hand')
  local buttons = read[1].frame.buttons
  expect.equal(buttons.right, true, 'the trigger presses the mapped button')
  expect.equal(buttons.left, nil, 'the mapping replaces the default wholesale')
  env.session:close()
end)

test('a laser reader cancels on loss and requires all buttons up before reacquisition', function()
  local env = start()
  local tracked, held = true, true
  local events = {}
  local target = {
    dead = false,
    grabbable = false,
    raycast = function()
      return 10, 20, 1
    end,
    onPointer = function(_self, event)
      if event.kind == 'press' or event.kind == 'release' or event.kind == 'cancel' then
        events[#events + 1] = event
      end
    end,
  }
  local beam = env.service:new(env.owner, 'right', {
    readInput = function()
      if not tracked then
        return nil
      end
      local input = frame(0, 0, -1)
      input.buttons.left = held
      return input
    end,
  })
  beam:update { target }
  expect.equal(events[1].kind, 'press', 'the trigger starts a gesture')
  tracked = false
  beam:update { target }
  expect.equal(events[2].reason, 'tracking-loss', 'tracking loss cancels rather than releases')
  tracked = true
  beam:update { target }
  expect.equal(#events, 2, 'a held trigger after reacquisition cannot press again')
  held = false
  beam:update { target }
  held = true
  beam:update { target }
  expect.equal(events[3].kind, 'press', 'a fresh edge after an observed release presses again')
  env.session:close()
end)

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
  local borrowed = env.service:new(env.owner, 'left', {
    seat = seat,
    readInput = function()
      return nil
    end,
    style = { length = 9 },
  })
  expect.equal(borrowed.seat, seat, 'the borrowed seat')
  expect.falsy(borrowed.ownsSeat, 'a borrowed seat is not owned')
  expect.equal(borrowed.style.length, 9, "a laser's own style")

  local attached = env.service:attach(env.owner, {
    readInput = function()
      return nil
    end,
  })
  expect.equal(#attached, 2, 'the attached lasers')
  expect.equal(attached[1], borrowed, "attach answers the owner's own laser for a hand it holds")
  expect.equal(attached[2].hand, 'right', 'the free hand')
  expect.truthy(attached[2].ownsSeat and attached[2].seat ~= seat, 'the free hand gets a seat of its own')
  expect.equal(env.service:forHand 'left', borrowed, 'forHand')
  expect.equal(#interaction(env):pointers(), 2, 'each laser is a pointer')

  expect.equal(env.service:attach(env.owner)[2], attached[2], 'attach is idempotent')

  local rival = env.session:observe(laserContract.capability)
  expect.raises(function()
    env.service:attach(rival.context)
  end, 'another owner holds', 'attach for a hand another owner holds')

  local ownedSeat = attached[2].seat
  attached[2]:destroy()
  expect.truthy(ownedSeat.dead, 'an owned seat ends with the laser')
  expect.equal(#interaction(env):pointers(), 1, 'a destroyed laser releases its pointer')
  env.consumer.instance:disable()
  expect.equal(#env.service:all(), 0, 'the lasers after the owner unloads')
  expect.equal(#interaction(env):pointers(), 0, 'the pointers after the owner unloads')
  expect.falsy(seat.dead, 'a borrowed seat outlives the laser')
  env.session:close()
end)

return test
