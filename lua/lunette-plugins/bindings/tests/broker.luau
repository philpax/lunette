local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local bindingsContract = require '@lunette-contracts/bindings'
local frameContract = require '@lunette-contracts/frame'

local test = testing.suite()

local function start()
  local env = { ran = {}, delivered = {} }
  env.session = testing.boot { 'frame', 'bindings' }
  env.native = env.session.native
  env.hotkeys = env.session:use(adapter.define {
    name = 'hotkeys',
    requires = { bindingsContract.capability, frameContract.capability },
    init = function(context)
      env.owner = context
      env.bindings = context:require(bindingsContract.capability)
      env.bindings:register(context, {
        chord = { key = 'backspace', modifiers = { 'alt', 'control' } },
        run = function(press)
          env.ran[#env.ran + 1] = press
        end,
      })
      env.bindings:register(context, {
        chord = { key = 'f9' },
        run = function()
          error 'binding failure'
        end,
      })
    end,
  })
  local frame = env.session:observe(frameContract.capability)
  frame.service:onKey(frame.context, {
    phase = 'delivery',
    run = function(event)
      env.delivered[#env.delivered + 1] = event.key
    end,
  })
  return env
end

local function press(env, key, held, isRepeat)
  env.native.events.held = {}
  for _, name in ipairs(held) do
    env.native.events.held[name] = true
  end
  lovr.keypressed(key, 0, isRepeat == true)
  env.native.events.held = {}
end

test('a chord matches with exactly its modifiers held, whatever order, and is consumed before delivery', function()
  local env = start()
  press(env, 'backspace', {})
  expect.equal(#env.delivered, 1, 'an unbound press reaches delivery')
  press(env, 'backspace', { 'lctrl', 'lalt' })
  expect.equal(#env.ran, 1, 'the binding ran')
  expect.equal(env.ran[1].key, 'backspace', 'the key of the press the binding was given')
  expect.equal(#env.delivered, 1, 'a bound press does not reach delivery')
  press(env, 'backspace', { 'lctrl', 'lalt' }, true)
  expect.equal(#env.ran, 1, 'a repeat does not run the binding again')
  expect.equal(#env.delivered, 1, 'a repeat does not reach delivery')
  press(env, 'backspace', { 'lctrl', 'lalt', 'lshift' })
  expect.equal(#env.ran, 1, 'another modifier set is another chord')
  expect.equal(#env.delivered, 2, 'the press of another modifier set reaches delivery')
  press(env, 'f9', {})
  local reported = env.native.events.reported
  expect.equal(#reported, 1, 'the errors reported')
  expect.truthy(reported[1].message:find('binding failure', 1, true), 'the report: ' .. reported[1].message)
  expect.equal(#env.delivered, 2, 'a press whose binding raised is still consumed')
  env.session:close()
end)

test('a chord is bound once, whatever order its modifiers are written in, and ends with its owner', function()
  local env = start()
  expect.raises(function()
    env.bindings:register(env.owner, {
      chord = { key = 'backspace', modifiers = { 'control', 'alt' } },
      run = function() end,
    })
  end, 'already registered', 'the second registration')
  env.hotkeys:disable()
  press(env, 'backspace', { 'lctrl', 'lalt' })
  expect.equal(#env.ran, 0, 'the runs of the binding')
  expect.equal(#env.delivered, 1, 'the press reaches delivery')
  env.session:close()
end)

return test
