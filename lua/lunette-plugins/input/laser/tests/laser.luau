local testing = require '@testing'
local expect = testing.expect
local laserContract = require '@lunette-contracts/laser'
local laser = require '../'
local vrUi = require '@testing/vr-ui'
local interactionContract = require '@lunette-contracts/interaction'

local test = testing.suite()

type PointerEvent = laserContract.PointerEvent
type Env = {
  native: testing.Native,
  controls: vrUi.Fixture?,
  session: testing.Session?,
  consumer: testing.Observed<laserContract.Service>?,
  service: laserContract.Service?,
  owner: testing.Context?,
}
type LaserDetails = { read hand: laserContract.Hand, read ownsSeat: boolean, read seatId: number? }
type BorrowedSeat = {
  dead: boolean,
  setFocus: ((BorrowedSeat) -> boolean)?,
  destroy: ((BorrowedSeat) -> boolean)?,
}

local function start(definition: testing.Definition<laser.Config>?): Env
  local env: Env = { native = testing.native() }
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

-- Counts the live pointers and the lasers' owned seats through inspection.
local function pointers(env: Env): number
  local count = 0
  for _, registration in env.session:observe(interactionContract.capability).service:inspect().registrations do
    if registration.kind == 'pointer' and registration.live then
      count += 1
    end
  end
  return count
end

local function lasers(env: Env): { [laserContract.Hand]: LaserDetails }
  local found: { [laserContract.Hand]: LaserDetails } = {}
  for _, registration in env.service:inspect().registrations do
    if registration.live then
      found[registration.details.hand] = registration.details
    end
  end
  return found
end

local function trigger(env: Env, held: boolean)
  env.controls:button('left', 'trigger', held)
  env.controls:button('right', 'trigger', held)
end

local function calls(env: Env, name: string): { testing.DrawCall }
  local found: { testing.DrawCall } = {}
  for _, call in ipairs(env.native.events.draw) do
    if call[1] == name then
      found[#found + 1] = call
    end
  end
  return found
end

local function frame(x: number, y: number, z: number): laserContract.Input
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
  local pressed: { testing.PointerButton } = {}
  local target = {
    dead = false,
    raycast = function(): (number, number, number)
      return 1, 2, 3
    end,
    onPointer = function(_: laserContract.Surface, event: PointerEvent)
      if event.kind == 'press' then
        pressed[#pressed + 1] = event.button
      end
    end,
  }
  for _, each in env.service:attach(env.owner) do
    env.service:update { target }
    each:destroy()
  end
  expect.equal(pressed[1], 'left', 'the default reader maps the trigger to the left button')
  env.native.events.haptics = 0
  local inputs = { left = frame(0, 0, -1), right = frame(0, 1, 0) }
  env.service:attach(env.owner, {
    readInput = function(hand: laserContract.Hand): laserContract.Input?
      return inputs[hand]
    end,
    style = { hapticStrength = 0.3 },
  })
  env.service:update {}
  env.service:draw(env.native.events.pass)
  expect.equal(#calls(env, 'line'), 2, 'a beam per hand')
  expect.equal(#calls(env, 'sphere'), 0, 'no cursor without a hover')

  local hovers = 0
  local surface = {
    dead = false,
    raycast = function(_: laserContract.Surface, _: vector, direction: vector): (number?, number?, number?)
      if direction.y > 0.5 then
        return nil
      end
      return 1, 2, 3
    end,
    onPointer = function(_: laserContract.Surface, event: PointerEvent)
      if event.kind == 'enter' then
        hovers += 1
      end
    end,
  }
  env.service:update { surface }
  expect.equal(hovers, 1, 'the hovered surface')
  expect.equal(env.native.events.haptics, 1, 'one pulse')
  expect.equal(env.native.events.haptic.device, 'hand/left', "the pulse reaches the hovering hand's controller")
  expect.equal(env.native.events.haptic.strength, 0.3, 'the pulse strength')

  table.clear(env.native.events.draw)
  env.service:draw(env.native.events.pass)
  expect.equal(#calls(env, 'sphere'), 1, 'a cursor for the hovering hand')
  env.session:close()
end)

test('the readInput hook wraps the default for every laser, and buttons map the controller', function()
  local read: { { hand: laserContract.Hand, frame: laserContract.Input? } } = {}
  local hooked = laser.define {
    name = 'hooked-laser',
    buttons = { { control = 'trigger', button = 'right' } },
    readInput = function(hand: laserContract.Hand, base: laser.ReadBase): laserContract.Input?
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
  local events: { PointerEvent } = {}
  local target = {
    dead = false,
    grabbable = false,
    raycast = function(): (number, number, number)
      return 10, 20, 1
    end,
    onPointer = function(_self: laserContract.Surface, event: PointerEvent)
      if event.kind == 'press' or event.kind == 'release' or event.kind == 'cancel' then
        events[#events + 1] = event
      end
    end,
  }
  env.service:attach(env.owner, {
    readInput = function(hand: laserContract.Hand): laserContract.Input?
      if not tracked or hand ~= 'right' then
        return nil
      end
      local input = frame(0, 0, -1)
      input.buttons.left = held
      return input
    end,
  })
  env.service:update { target }
  expect.equal(events[1].kind, 'press', 'the trigger starts a gesture')
  tracked = false
  env.service:update { target }
  expect.equal(events[2].reason, 'tracking-loss', 'tracking loss cancels rather than releases')
  tracked = true
  env.service:update { target }
  expect.equal(#events, 2, 'a held trigger after reacquisition cannot press again')
  held = false
  env.service:update { target }
  held = true
  env.service:update { target }
  expect.equal(events[3].kind, 'press', 'a fresh edge after an observed release presses again')
  env.session:close()
end)

local function borrowedSeat(): BorrowedSeat
  local seat: BorrowedSeat = { dead = false }
  function seat.setFocus(_self: BorrowedSeat): boolean
    return true
  end
  function seat.destroy(self: BorrowedSeat): boolean
    self.dead = true
    return true
  end
  return seat
end

test('a hand has one laser, which attach answers to its own owner, and a laser owns only a seat it made', function()
  local env = start()
  local function silent(): nil
    return nil
  end
  local attached = env.service:attach(env.owner, { readInput = silent })
  expect.equal(#attached, 2, 'the attached lasers')
  expect.truthy(attached[1].hand == 'left' and attached[2].hand == 'right', 'a laser per hand, left first')
  expect.truthy(lasers(env).left.ownsSeat and lasers(env).right.ownsSeat, 'a laser without a seat makes its own')
  expect.equal(pointers(env), 2, 'each laser is a pointer')
  expect.equal(env.service:attach(env.owner)[2], attached[2], 'attach is idempotent')

  local rival = env.session:observe(laserContract.capability)
  expect.raises(function()
    env.service:attach(rival.context)
  end, 'another owner holds', 'attach for a hand another owner holds')

  local seatId = lasers(env).right.seatId
  attached[2]:destroy()
  expect.truthy(env.native.events.seats[seatId].dead, 'an owned seat ends with the laser')
  expect.equal(pointers(env), 1, 'a destroyed laser releases its pointer')
  attached[1]:destroy()

  local seat = borrowedSeat()
  local borrowed = env.service:attach(env.owner, { seat = seat, readInput = silent })
  expect.falsy(lasers(env).left.ownsSeat, 'a borrowed seat is not owned')
  expect.truthy(borrowed[1].pointer and not borrowed[1].dead, 'the laser and its pointer')
  env.consumer.instance:disable()
  expect.equal(#env.service:inspect().registrations, 0, 'the lasers after the owner unloads')
  expect.equal(pointers(env), 0, 'the pointers after the owner unloads')
  expect.falsy(seat.dead, 'a borrowed seat outlives the laser')
  env.session:close()
end)

test('a hand reported near stands its idle ray down until the report ends', function()
  local env = start()
  local interaction = env.session:observe(interactionContract.capability)
  local service, reporter = interaction.service, interaction.context
  local inputs = { left = frame(0, 0, -1), right = frame(0, 0, -1) }
  env.service:attach(env.owner, {
    readInput = function(hand: laserContract.Hand): laserContract.Input?
      return inputs[hand]
    end,
  })
  local entered: { [string]: number } = {}
  local surface = {
    dead = false,
    raycast = function(): (number, number, number)
      return 1, 2, 3
    end,
    onPointer = function(_: laserContract.Surface, event: PointerEvent)
      entered[event.kind] = (entered[event.kind] or 0) + 1
    end,
  }
  service:reportNear(reporter, 'left', true)
  expect.truthy(service:isNear 'left', 'the left hand is near')
  expect.falsy(service:isNear 'right', 'the right hand is not')
  env.service:update { surface }
  expect.equal(entered.enter, 1, 'only the far hand hovers the surface')
  table.clear(env.native.events.draw)
  env.service:draw(env.native.events.pass)
  expect.equal(#calls(env, 'line'), 1, 'the near hand draws no beam')

  service:reportNear(reporter, 'left', false)
  env.service:update { surface }
  expect.equal(entered.enter, 2, 'the ray returns when the hand is no longer near')
  table.clear(env.native.events.draw)
  env.service:draw(env.native.events.pass)
  expect.equal(#calls(env, 'line'), 2, 'both beams draw')
  env.session:close()
end)

test('a ray holding a button keeps going when its hand becomes near', function()
  local env = start()
  local interaction = env.session:observe(interactionContract.capability)
  local held = frame(0, 0, -1)
  held = table.clone(held) :: any
  (held :: any).buttons = { left = true }
  local inputs = { left = held, right = nil }
  env.service:attach(env.owner, {
    readInput = function(hand: laserContract.Hand): laserContract.Input?
      return inputs[hand]
    end,
  })
  local kinds: { string } = {}
  local surface = {
    dead = false,
    raycast = function(): (number, number, number)
      return 1, 2, 3
    end,
    onPointer = function(_: laserContract.Surface, event: PointerEvent)
      table.insert(kinds, event.kind)
    end,
  }
  env.service:update { surface }
  interaction.service:reportNear(interaction.context, 'left', true)
  env.service:update { surface }
  expect.falsy(table.find(kinds, 'leave'), 'the pressing ray does not leave its surface')
  inputs.left = frame(0, 0, -1)
  env.service:update { surface }
  env.service:update { surface }
  expect.truthy(table.find(kinds, 'release'), 'the press releases normally')
  expect.truthy(table.find(kinds, 'leave'), 'the idle ray then stands down')
  env.session:close()
end)

test('near reports end with their owner', function()
  local env = start()
  local interaction = env.session:observe(interactionContract.capability)
  local session = assert(env.session)
  local child: any = nil
  local instance = session:use(
    require('@lunette-plugin/adapter').define {
      name = 'testing/near-reporter',
      requires = { interactionContract.capability },
      init = function(context: any)
        child = context
        context:require(interactionContract.capability):reportNear(context, 'right', true)
      end,
    },
    {}
  )
  expect.truthy(child, 'the reporter started')
  expect.truthy(interaction.service:isNear 'right', 'the report holds')
  instance:disable()
  session.runtime:drain()
  expect.falsy(interaction.service:isNear 'right', 'the report ends with its owner')
  env.session:close()
end)

return test
