local testing = require '@testing'
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local lunette = require '@lunette'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local surfaces = require '@lunette-contracts/surfaces'
local display = require '@lunette-contracts/keyboard-display'
local expect = testing.expect
local test = testing.suite()

local function start()
  local env = {}
  env.session = testing.boot {
    'frame',
    'theme',
    'surfaces',
    'focus',
    'keyboard',
    'ui',
    { id = 'desktop/keyboard', definition = require '@lunette-plugins/keyboard-display' },
    {
      id = 'fields',
      definition = adapter.define {
        name = 'testing/display-fields',
        requires = { ui.capability, focus.capability },
        init = function(context)
          env.owner = context
          env.focus = context:require(focus.capability)
          local panel = context:require(ui.capability):newPanel(context, {
            name = 'Display fields',
            width = 1,
            height = 1,
            logicalWidth = 200,
            logicalHeight = 200,
          })
          env.first = panel:textField {
            id = 'first',
            value = 'draft',
            bounds = { x = 10, y = 10, width = 180, height = 30 },
          }
          env.second = panel:textField { id = 'second', bounds = { x = 10, y = 60, width = 180, height = 30 } }
        end,
      },
    },
  }
  env.keyboard = env.session:observe(keyboard.capability).service
  env.surfaces = env.session:observe(surfaces.capability).service
  env.display = env.session:observe(display.capability).service
  return env
end

local function shown(env)
  for _, candidate in env.surfaces:all() do
    if candidate.setLayer then
      return candidate
    end
  end
  return nil
end

local function boards(env)
  return #env.keyboard:inspect().registrations
end

local function nativeTarget(env)
  local seat = lunette.newSeat { name = 'display-native' }
  env.owner:effect(function()
    return function()
      seat:destroy()
    end
  end)
  return env.focus:register(env.owner, {
    kind = 'native',
    seat = seat,
    sink = env.session.native.newMonitor('display-native').sink,
  })
end

test('field focus shows one keyboard that field changes keep in place, and leaving the fields hides it', function()
  local env = start()
  expect.equal(boards(env), 0, 'the keyboard is created on first use')
  expect.truthy(env.first:focus())
  local board = shown(env)
  expect.truthy(board, 'field focus shows a keyboard')
  board:setPose(lovr.math.newMat4():translate(3, 2, 1))
  expect.truthy(env.second:focus())
  expect.equal(shown(env), board, 'a field change reuses the keyboard')
  expect.equal(vector.pack(board.pose:getPosition()), vector.pack(3, 2, 1), 'a field change does not place it again')
  expect.truthy(env.first:focus())
  expect.truthy(nativeTarget(env):focus())
  expect.equal(shown(env), nil, 'focusing a native route hides it')
  expect.truthy(env.second:focus())
  expect.truthy(env.second:blur())
  expect.equal(shown(env), nil, 'ending editing hides it')
  expect.equal(boards(env), 1, 'hiding keeps the one keyboard')
end)

test('a manual show outlives the field, and hide ends editing and keeps the draft', function()
  local env = start()
  local native = nativeTarget(env)
  expect.truthy(env.display:show())
  local board = shown(env)
  expect.truthy(env.first:focus())
  expect.truthy(native:focus())
  expect.equal(shown(env), board, 'manual visibility survives leaving a field')
  expect.truthy(env.first:focus())
  expect.equal(env.focus:newSource(env.owner):text('!').kind, 'consumed', 'the field takes typed text')
  expect.truthy(env.display:hide())
  expect.equal(shown(env), nil, 'hide withdraws the keyboard')
  expect.equal(env.focus:focused(), nil, 'hide blurs the field')
  expect.equal(env.first:value(), 'draft!', 'hide keeps the draft')
  expect.truthy(env.first:focus())
  expect.equal(shown(env), board, 'a fresh focus resumes on the same keyboard')
end)

return test
