local testing = require '@testing'
local expect = testing.expect
local display = require '@lunette-contracts/keyboard-display'
local surfaces = require '@lunette-contracts/surfaces'
local test = testing.suite()

type Environment = { session: testing.Session?, surfaces: surfaces.Service?, display: display.Service? }
type Config = { read placement: { read distance: number?, read drop: number?, read tilt: number? }? }
type Board = { read pose: Mat4 }

local function start(config: Config?): Environment
  local env: Environment = {}
  env.session = testing.boot {
    'frame',
    'theme',
    'surfaces',
    'focus',
    'drops',
    'interaction',
    'ui-host',
    'ui-standard',
    'keyboard',
    { id = 'desktop/keyboard', definition = require('../').definition, config = config },
  }
  env.surfaces = env.session:observe(surfaces.capability).service
  env.display = env.session:observe(display.capability).service
  return env
end

local function shown(env: Environment): Board?
  for _, candidate in env.surfaces:all() do
    if candidate.setLayer then
      return candidate
    end
  end
  return nil
end

local function expectVector(actual: vector, wanted: vector, label: string)
  expect.near(actual.x, wanted.x, 1e-5, label .. ' x')
  expect.near(actual.y, wanted.y, 1e-5, label .. ' y')
  expect.near(actual.z, wanted.z, 1e-5, label .. ' z')
end

local function axis(board: Board, x: number, y: number, z: number): vector
  return vector.pack(board.pose:mul(x, y, z, 0))
end

test('each show places the keyboard level in front of the head and tilted toward it', function()
  local env = start { placement = { distance = 0.8, drop = 0.25, tilt = math.pi / 6 } }
  lovr.headset.getPosition = function(): (number, number, number)
    return 0, 1.5, 0
  end
  lovr.headset.getDirection = function(): (number, number, number)
    return 1, -0.2, 0
  end
  expect.truthy(env.display:show())
  local board = shown(env)
  expectVector(vector.pack(board.pose:getPosition()), vector.pack(0.8, 1.25, 0), 'the position')
  expectVector(axis(board, 1, 0, 0), vector.pack(0, 0, 1), 'the horizontal axis')
  expectVector(axis(board, 0, 1, 0), vector.pack(0.5, math.sqrt(0.75), 0), 'the tilted vertical axis')

  lovr.headset.getPosition = function(): (number, number, number)
    return 2, 3, 4
  end
  env.session:update()
  expectVector(vector.pack(board.pose:getPosition()), vector.pack(0.8, 1.25, 0), 'a shown keyboard stays put')
  expect.truthy(env.display:toggle(), 'toggle hides the keyboard')
  expect.equal(shown(env), nil, 'the keyboard is withdrawn')

  lovr.headset.getDirection = function(): (number, number, number)
    return 0, 1, 0
  end
  expect.truthy(env.display:toggle(), 'toggle shows the keyboard')
  expect.equal(shown(env), board, 'a later show reuses the keyboard')
  expectVector(vector.pack(board.pose:getPosition()), vector.pack(2, 2.75, 3.2), 'looking straight up faces forward')
end)

return test
