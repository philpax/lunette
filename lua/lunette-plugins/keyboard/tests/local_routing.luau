local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local focusContract = require '@lunette-contracts/focus'
local keyboardContract = require '@lunette-contracts/keyboard'

local test = testing.suite()

local function start()
  local env = { native = testing.native(), keys = {}, texts = {} }
  env.session = testing.start { 'focus', 'keyboard' }
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

test('a local route takes precedence over a native target adapter for both providers', function()
  local env = start()
  local adapterCalls = 0
  local options = {
    target = function()
      adapterCalls += 1
      error 'a local route must not consult a native adapter'
    end,
  }
  local board = env.keyboard:new(env.owner, options)
  expect.truthy(board:pressKey(30))
  expect.equal(env.keys[1].code, 30)
  expect.equal(env.keys[1].source, 'virtual')
  expect.equal(#env.texts, 0, 'a key legend is not text input')
  expect.truthy(board:typeText 'committed UTF-8')
  expect.equal(env.texts[1], 'committed UTF-8')
  expect.equal(board:keys()[1].legend, 'keymap legend')
  expect.equal(adapterCalls, 0)
  env.session:close()

  testing.host.useConfiguration 'examples/keyboard'
  local tiny = require 'tiny'
  env = start()
  env.session.instances.keyboard:disable()
  env.session:use(tiny)
  local observed = env.session:observe(keyboardContract.capability)
  local replacement = observed.service:new(observed.context, options)
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
  expect.equal(adapterCalls, 0)
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

test('a changed native adapter target does not receive latches or locks from its previous route', function()
  local env = start()
  env.target:blur()
  local seat = { id = 9, dead = false }
  function seat:setFocus(sink)
    self.focus = sink
    return true
  end
  local first = { domain = 'host', monitor = { id = 8 }, dead = false }
  local second = { domain = 'host', monitor = { id = 9 }, dead = false }
  local sent = {}
  for _, sink in { first, second } do
    function sink:modifiers(held)
      sent[#sent + 1] = { sink = self, modifiers = table.clone(held) }
      return true
    end
    function sink:key()
      return true
    end
  end
  local selected = first
  local board = env.keyboard:new(env.owner, {
    target = function()
      return seat, selected
    end,
  })
  expect.truthy(board:pressKey(30), 'the first adapter target establishes its route')
  board:pressKey(42)
  board:pressKey(58)
  expect.equal(table.concat(board:modifiers(), '+'), 'shift+capsLock')
  table.clear(sent)
  expect.truthy(board:pressKey(31), 'the same native route receives its current modifiers')
  expect.equal(table.concat(sent[1].modifiers, '+'), 'shift+capsLock', 'the latch and lock apply on the same route')
  expect.equal(table.concat(board:modifiers(), '+'), 'capsLock', 'a same-route activation consumes only the latch')
  board:pressKey(42)
  selected = second
  table.clear(sent)
  expect.truthy(board:pressKey(32), 'the adapter establishes the replacement native route')
  expect.equal(#board:modifiers(), 0, 'the route notification clears the latch and lock immediately')
  local deliveries = 0
  for _, event in sent do
    if event.sink == second then
      deliveries += 1
      expect.equal(#event.modifiers, 0, 'the new sink receives no latch or lock from the old route')
    end
  end
  expect.equal(deliveries, 2, 'the replacement sink receives the activation and modifier release')
  table.clear(sent)
  expect.truthy(board:pressKey(33), 'the next activation stays on the replacement route')
  expect.equal(#sent[1].modifiers, 0, 'no old modifier returns on the next activation')
  env.session:close()
end)

test('the tiny provider routes native adapter changes through its source without modifiers', function()
  testing.host.useConfiguration 'examples/keyboard'
  local env = start()
  env.session.instances.keyboard:disable()
  env.session:use(require 'tiny')
  local observed = env.session:observe(keyboardContract.capability)
  local seat = { id = 9, dead = false }
  local first = { domain = 'host', monitor = { id = 8 }, dead = false }
  local second = { domain = 'host', monitor = { id = 9 }, dead = false }
  local sent = {}
  for _, sink in { first, second } do
    function sink:modifiers(held)
      sent[#sent + 1] = { sink = self, modifiers = table.clone(held) }
      return true
    end
    function sink:key()
      return true
    end
  end
  local selected = first
  local board = observed.service:new(observed.context, {
    target = function()
      return seat, selected
    end,
  })
  expect.truthy(board:pressKey(21), 'the first adapter target establishes its route')
  selected = second
  table.clear(sent)
  expect.truthy(board:pressKey(49), 'the replacement target establishes its route')
  expect.equal(#sent, 2, 'the replacement receives the activation and modifier release')
  for _, event in sent do
    expect.equal(event.sink, second, 'the source delivers only to the selected target')
    expect.equal(#event.modifiers, 0, 'tiny has no latched or locked modifiers')
  end
  expect.truthy(board:destroy())
  expect.falsy(board:pressKey(21), 'destruction makes the retained board inert')
  env.session:close()
end)

test('physical source metadata is copied before native selection and route notifications', function()
  local env = start()
  env.target:blur()
  local held = { 'mod5' }
  local physical = { shift = true, control = true, alt = true, super = false, capsLock = true, numLock = true }
  local activation = { code = 30, modifiers = held, physicalModifiers = physical, isRepeat = false }
  local function mutate()
    table.clear(held)
    for name in physical do
      physical[name] = false
    end
    activation.code = 31
    activation.modifiers = { 'alt' }
    activation.physicalModifiers = physical
    activation.isRepeat = true
    activation.batch = 99
  end
  local seat = { id = 9, dead = false }
  local sent, codes = {}, {}
  local sink = { domain = 'host', monitor = { id = 8 }, dead = false }
  function sink:modifiers(modifiers)
    sent[#sent + 1] = table.concat(modifiers, '+')
    return true
  end
  function sink:key(code)
    codes[#codes + 1] = code
    return true
  end
  env.focus:onChanged(env.owner, { run = mutate })
  local source = env.focus:newSource(env.owner, {
    mode = 'physical',
    nativeTarget = function()
      mutate()
      return seat, sink
    end,
  })
  expect.equal(source:key(activation).kind, 'consumed', 'callbacks cannot replace physical event metadata')
  expect.equal(sent[1], 'control+mod5+shift+capsLock+numLock', 'held and locked state comes from the original event')
  expect.equal(sent[2], '', 'native modifier cleanup still runs')
  expect.equal(table.concat(codes, ','), '30,30', 'both halves of the stroke use the original keycode')
  env.session:close()
end)

for index, corrupt in
  {
    function(held)
      held[1] = false
    end,
    function(held)
      held[3] = 'alt'
    end,
    function(held)
      setmetatable(held, {})
    end,
  }
do
  test('virtual source modifiers changed to invalid data during selection are refused ' .. index, function()
    local env = start()
    env.target:blur()
    local held = { 'shift' }
    local seat = { id = 9, dead = false }
    local deliveries = 0
    local sink = { domain = 'host', monitor = { id = 8 }, dead = false }
    function sink:modifiers()
      deliveries += 1
      return true
    end
    function sink:key()
      deliveries += 1
      return true
    end
    local source = env.focus:newSource(env.owner, {
      nativeTarget = function()
        corrupt(held)
        return seat, sink
      end,
    })
    expect.equal(source:key({ code = 30, modifiers = held }).kind, 'refused', 'changed modifiers are validated again')
    expect.equal(deliveries, 0, 'malformed modifiers never reach the native sink')
    env.session:close()
  end)
end

return test
