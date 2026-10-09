local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local focusContract = require '@lunette-contracts/focus'
local keyboardContract = require '@lunette-contracts/keyboard'

local test = testing.suite()

local function start()
  local env = { native = testing.native(), keys = {}, texts = {} }
  env.session = testing.start { 'theme', 'focus', 'keyboard' }
  env.session:use(plugin.define {
    name = 'local-keyboard-owner',
    requires = { keyboard = keyboardContract.capability, focus = focusContract.capability },
    init = function(context)
      env.owner = context
      env.keyboard, env.focus = context:require(keyboardContract.capability), context:require(focusContract.capability)
    end,
  })
  env.seat = { dead = false }
  function env.seat:characterFor()
    return 'keymap legend'
  end
  function env.seat:symbolFor()
    return nil
  end
  env.target = env.focus:register(env.owner, {
    kind = 'local',
    keymapSeat = env.seat,
    wantsKeyboard = true,
    receiver = {
      key = function(event)
        env.keys[#env.keys + 1] = event
        return true
      end,
      text = function(text)
        env.texts[#env.texts + 1] = text
        return true
      end,
    },
  })
  expect.truthy(env.target:focus())
  return env
end

test('a local route receives keys, text, and keymap legends for both providers', function()
  local env = start()
  local board = env.keyboard:new(env.owner)
  expect.truthy(board:pressKey(30))
  expect.equal(env.keys[1].code, 30)
  expect.equal(env.keys[1].source, 'virtual')
  expect.equal(#env.texts, 0, 'a key legend is not text input')
  expect.truthy(board:typeText 'committed UTF-8')
  expect.equal(env.texts[1], 'committed UTF-8')
  expect.equal(board:keys()[1].legend, 'keymap legend')
  env.session:close()

  testing.host.useConfiguration 'examples/keyboard'
  local tiny = require 'tiny'
  env = start()
  env.session.instances.keyboard:disable()
  env.session:use(tiny)
  local observed = env.session:observe(keyboardContract.capability)
  local replacement = observed.service:new(observed.context)
  local targetOwner = env.session:observe(focusContract.capability)
  targetOwner.service
    :register(targetOwner.context, {
      kind = 'local',
      wantsKeyboard = true,
      receiver = {
        key = function(event)
          env.keys[#env.keys + 1] = event
          return true
        end,
        text = function(text)
          env.texts[#env.texts + 1] = text
          return true
        end,
      },
    })
    :focus()
  expect.truthy(replacement:pressKey(21))
  expect.truthy(replacement:typeText 'tiny local')
  expect.equal(env.keys[#env.keys].code, 21)
  expect.equal(env.texts[#env.texts], 'tiny local')
  env.session:close()
end)

test('a reentrant local focus change clears modifiers before the next activation', function()
  local env = start()
  local secondKeys = {}
  local second = env.focus:register(env.owner, {
    kind = 'local',
    wantsKeyboard = true,
    receiver = {
      key = function(event)
        secondKeys[#secondKeys + 1] = event
        return true
      end,
      text = function()
        return false
      end,
    },
  })
  local first = env.focus:register(env.owner, {
    kind = 'local',
    wantsKeyboard = true,
    receiver = {
      key = function()
        expect.truthy(second:focus())
        return false
      end,
      text = function()
        return false
      end,
    },
  })
  first:focus()
  local board = env.keyboard:new(env.owner)
  board:pressKey(42)
  board:pressKey(58)
  expect.falsy(board:pressKey(30), 'the route changes during the first receiver delivery')
  expect.equal(#board:modifiers(), 0, 'the route changed during delivery')
  expect.truthy(board:pressKey(31))
  expect.equal(#secondKeys[1].modifiers, 0, 'the next route receives no old latch or lock')
  env.session:close()
end)

return test
