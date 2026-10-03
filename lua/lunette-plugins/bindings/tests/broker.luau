-- Covers the bindings provider over the frame provider's key phases: a chord matched with exactly its
-- modifiers held and consumed before delivery, repeats, a chord bound once, a raising binding, malformed
-- registrations, and a binding that ends with its owner.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local bindingsContract = require '@lunette-contracts/bindings'
local frameContract = require '@lunette-contracts/frame'

local test = testing.suite()

-- The provider over the frame provider, a plugin of the test whose context is `owner` binding control+alt+
-- backspace and a raising F9, and a delivery-phase handler recording each key that gets past the bindings,
-- as a focused client would receive it.
local function start()
  local env = { ran = {}, delivered = {} }
  env.session = testing.boot { 'frame', 'bindings' }
  env.native = env.session.native
  env.hotkeys = env.session:use(plugin.define {
    name = 'hotkeys',
    requires = { bindings = bindingsContract.capability, frame = frameContract.capability },
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

-- Presses `key` with the keys in `held` held down.
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
  env.session:close()
end)

test('a repeat of a bound press is consumed without running the binding again', function()
  local env = start()
  press(env, 'backspace', { 'lctrl', 'lalt' })
  press(env, 'backspace', { 'lctrl', 'lalt' }, true)
  expect.equal(#env.ran, 1, 'the runs of the binding')
  expect.equal(#env.delivered, 0, 'the presses delivered')
  env.session:close()
end)

test('another modifier set is another chord', function()
  local env = start()
  press(env, 'backspace', { 'lctrl', 'lalt', 'lshift' })
  expect.equal(#env.ran, 0, 'the runs of the binding')
  expect.equal(#env.delivered, 1, 'the presses delivered')
  env.session:close()
end)

test('a chord is bound once, whatever order its modifiers are written in', function()
  local env = start()
  expect.raises(function()
    env.bindings:register(env.owner, {
      chord = { key = 'backspace', modifiers = { 'control', 'alt' } },
      run = function() end,
    })
  end, 'already bound', 'the second registration')
  env.session:close()
end)

test('a binding that raises is reported, and its press is still consumed', function()
  local env = start()
  press(env, 'f9', {})
  -- The broker reports through the native error boundary, as a raising native callback is reported.
  local reported = env.native.events.reported
  expect.equal(#reported, 1, 'the errors reported')
  expect.truthy(reported[1].message:find('binding failure', 1, true), 'the report: ' .. reported[1].message)
  expect.equal(#env.delivered, 0, 'the presses delivered')
  env.session:close()
end)

test('a malformed registration raises at the call', function()
  local env = start()
  for _, case in ipairs {
    { binding = { chord = { key = '' }, run = function() end }, pattern = 'chord.key is a key name' },
    {
      binding = { chord = { key = 'x', modifiers = { 'hyper' } }, run = function() end },
      pattern = 'chord.modifiers%[1%] is one of',
    },
    { binding = { chord = { key = 'x' }, run = 'reload' }, pattern = 'run is a function' },
  } do
    expect.raises(function()
      env.bindings:register(env.owner, case.binding)
    end, case.pattern, 'the registration')
  end
  env.session:close()
end)

test('a binding ends with its owner', function()
  local env = start()
  env.hotkeys:disable()
  press(env, 'backspace', { 'lctrl', 'lalt' })
  expect.equal(#env.ran, 0, 'the runs of the binding')
  expect.equal(#env.delivered, 1, 'the press reaches delivery')
  env.session:close()
end)

return test
