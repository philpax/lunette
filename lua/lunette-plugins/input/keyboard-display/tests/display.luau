local testing = require '@testing'
local lunette = require '@lunette'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local surfaces = require '@lunette-contracts/surfaces'
local display = require '@lunette-contracts/keyboard-display'
local fields = require './support/fields'
local expect = testing.expect
local test = testing.suite()

type Environment = {
  session: testing.Session?,
  fields: fields.Fields,
  keyboard: keyboard.Service?,
  surfaces: surfaces.Service?,
  display: display.Service?,
}
type Board = { read pose: Mat4, read setPose: (Board, Mat4) -> () }

local function start(): Environment
  local env: Environment = { fields = fields.new() }
  env.session = testing.boot {
    'frame',
    'theme',
    'surfaces',
    'focus',
    'drops',
    'interaction',
    'keyboard',
    'ui-host',
    'ui-standard',
    { id = 'desktop/keyboard', definition = require('../').definition },
    { id = 'fields', definition = fields.definition(env.fields, { name = 'Display fields' }) },
  }
  env.keyboard = env.session:observe(keyboard.capability).service
  env.surfaces = env.session:observe(surfaces.capability).service
  env.display = env.session:observe(display.capability).service
  env.session:update()
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

local function boards(env: Environment): number
  return #env.keyboard:inspect().registrations
end

local function field(env: Environment, which: 'first' | 'second'): any
  return fields.node(if which == 'first' then env.fields.first else env.fields.second)
end

local function nativeTarget(env: Environment): focus.TargetHandle
  local owner = assert(env.fields.owner)
  local seat = lunette.newSeat { name = 'display-native' }
  owner:effect(function(): () -> ()
    return function()
      seat:destroy()
    end
  end)
  return assert(env.fields.focus):register(owner, {
    kind = 'native',
    seat = seat,
    sink = env.session.native.newMonitor('display-native').sink,
  })
end

test('field focus shows one keyboard that field changes keep in place, and leaving the fields hides it', function()
  local env = start()
  expect.equal(boards(env), 0, 'the keyboard is created on first use')
  expect.truthy(field(env, 'first'):focus())
  local board = shown(env)
  expect.truthy(board, 'field focus shows a keyboard')
  board:setPose(lovr.math.newMat4():translate(3, 2, 1))
  expect.truthy(field(env, 'second'):focus())
  expect.equal(shown(env), board, 'a field change reuses the keyboard')
  expect.equal(vector.pack(board.pose:getPosition()), vector.pack(3, 2, 1), 'a field change does not place it again')
  expect.truthy(field(env, 'first'):focus())
  expect.truthy(nativeTarget(env):focus())
  expect.equal(shown(env), nil, 'focusing a native route hides it')
  expect.truthy(field(env, 'second'):focus())
  field(env, 'second'):blur()
  expect.equal(shown(env), nil, 'ending editing hides it')
  expect.equal(boards(env), 1, 'hiding keeps the one keyboard')
end)

test('a manual show outlives the field, and hide ends editing and keeps the draft', function()
  local env = start()
  local native = nativeTarget(env)
  expect.truthy(env.display:show())
  local board = shown(env)
  expect.truthy(field(env, 'first'):focus())
  expect.truthy(native:focus())
  expect.equal(shown(env), board, 'manual visibility survives leaving a field')
  expect.truthy(field(env, 'first'):focus())
  local source = assert(env.fields.focus):newSource(assert(env.fields.owner))
  expect.equal(source:text('!').kind, 'consumed', 'the field takes typed text')
  expect.truthy(env.display:hide())
  expect.equal(shown(env), nil, 'hide withdraws the keyboard')
  expect.equal(assert(env.fields.focus):focused(), nil, 'hide blurs the field')
  expect.equal(env.fields.values.first, 'draft!', 'hide keeps the draft')
  expect.truthy(field(env, 'first'):focus())
  expect.equal(shown(env), board, 'a fresh focus resumes on the same keyboard')
end)

return test
