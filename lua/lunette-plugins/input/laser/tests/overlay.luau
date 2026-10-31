local testing = require '@testing'
local expect = testing.expect
local laserContract = require '@lunette-contracts/laser'
local laser = require '../'
local vrUi = require '@testing/vr-ui'

local test = testing.suite()

type Env = {
  native: testing.Native,
  service: laserContract.Service,
  owner: testing.Context,
  session: testing.Session,
}

local function start(config: laser.Config?): Env
  local native = testing.native()
  vrUi.hands(native)
  native.events.mainSessionVisible = true
  local session = testing.start {
    'theme',
    'drops',
    'focus',
    'interaction',
    { id = 'laser', definition = laser.definition, config = config or {} },
  }
  local observed = session:observe(laserContract.capability)
  return { native = native, service = observed.service, owner = observed.context, session = session }
end

local function aimed(x: number, y: number, z: number, buttons: { [string]: boolean }?): laserContract.Input
  return {
    pose = lovr.math.newMat4(),
    origin = vector.create(0, 0, 0),
    direction = vector.create(x, y, z),
    buttons = buttons or {},
    grip = false,
    dt = 1 / 60,
  }
end

-- A surface that answers only rays pointing ahead.
local SURFACE = {
  dead = false,
  raycast = function(_: laserContract.Surface, _: vector, direction: vector): (number?, number?, number?)
    if direction.z > -0.5 then
      return nil
    end
    return 1, 2, 3
  end,
  onPointer = function() end,
}

local function beams(env: Env): number
  table.clear(env.native.events.draw)
  env.service:draw(env.native.events.pass)
  local count = 0
  for _, call in ipairs(env.native.events.draw) do
    if call[1] == 'line' then
      count += 1
    end
  end
  return count
end

test('over another scene, only a beam engaged with content draws, and an idle one fades out', function()
  local env = start()
  local inputs = { left = aimed(0, 0, -1), right = aimed(0, 1, 0) }
  env.service:attach(env.owner, {
    readInput = function(hand: laserContract.Hand): laserContract.Input?
      return inputs[hand]
    end,
  })
  env.service:update { SURFACE }
  expect.equal(beams(env), 1, 'the beam hovering content draws and the idle one fades')
  inputs.left = aimed(0, 1, 0)
  env.service:update { SURFACE }
  expect.equal(beams(env), 1, 'a beam that leaves content fades rather than vanishing')
  for _ = 1, 20 do
    env.service:update { SURFACE }
  end
  expect.equal(beams(env), 0, 'idle beams are gone once they have faded')
  inputs.right = aimed(0, 1, 0, { left = true })
  env.service:update { SURFACE }
  expect.equal(beams(env), 1, 'a beam holding a button draws off content')
  env.native.events.mainSessionVisible = false
  inputs.right = aimed(0, 1, 0)
  env.service:update { SURFACE }
  expect.equal(beams(env), 2, 'without another scene every beam draws')
  env.session:close()
end)

test('the always mode draws idle beams over another scene', function()
  local env = start { overlayBeam = 'always' }
  env.service:attach(env.owner, {
    readInput = function(): laserContract.Input?
      return aimed(0, 1, 0)
    end,
  })
  env.service:update { SURFACE }
  expect.equal(beams(env), 2)
  env.session:close()
end)

return test
