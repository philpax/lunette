-- Covers a keyboard built from options: custom rows and their geometry, action keys and layers, the modifier
-- and lock sets, and the onKey and drawKey hooks wrapping the defaults.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local keyboardContract = require '@lunette-contracts/keyboard'
local interactionContract = require '@lunette-contracts/interaction'
local focusContract = require '@lunette-contracts/focus'
local keyboard = require '@lunette-plugins/keyboard'

local test = testing.suite()

local ROWS = {
  { { code = 30 }, { width = 0.5 }, { code = 31, x = 1 }, { code = 32, height = 2 } },
  { { code = 44, width = 2 }, { width = 1.5, height = 0.5 } },
  {},
  {
    { action = { kind = 'layer', layer = 'symbols' }, label = 'sym' },
    { action = { kind = 'custom', name = 'wave' } },
    { action = { kind = 'text', text = 'hi' } },
    { action = { kind = 'chord', code = 20, modifiers = { 'control', 'alt' } } },
    { action = { kind = 'hide' } },
  },
}
local SYMBOLS = { { { code = 2 }, { action = { kind = 'layer', layer = 'base' }, label = 'abc' } } }

-- A keyboard provider defined with the rows above and hooks that record what they see, its dependencies over
-- the fake native API, a consumer holding focus on a recording sink, a pointer that records its pulses, and a
-- keyboard.
local function start()
  local env = { native = testing.native(), pressed = {}, custom = {}, drawn = {}, sent = {}, pulses = {} }
  local definition = keyboard.define {
    name = 'custom-keyboard',
    rows = ROWS,
    layers = { symbols = SYMBOLS },
    style = { keyUnit = 1, gap = 0 },
    modifierKeys = { [42] = 'shift', [29] = 'control' },
    locks = { 'shift' },
    onKey = function(board, key, pointer, base)
      env.pressed[#env.pressed + 1] = key
      pointer:vibrate { strength = 0.5, duration = 0.02 }
      local action = key.action
      if action and action.kind == 'custom' then
        env.custom[#env.custom + 1] = action.name
        return
      end
      base(board, key, pointer)
    end,
    drawKey = function(pass, key, state, base)
      env.drawn[#env.drawn + 1] = { key = key, held = state.held, hovered = state.hovered, board = state.keyboard }
      base(pass, key, state)
    end,
  }
  env.session = testing.start { 'drops', 'focus', 'interaction', { id = 'keyboard', definition = definition } }
  local service, owner, pointers, focus
  env.session:use(plugin.define {
    name = 'keyboard-options-test',
    requires = {
      keyboard = keyboardContract.capability,
      interaction = interactionContract.capability,
      focus = focusContract.capability,
    },
    init = function(context)
      service, owner = context:require(keyboardContract.capability), context
      pointers, focus = context:require(interactionContract.capability), context:require(focusContract.capability)
    end,
  })
  env.service, env.owner = service, owner

  local seat = { dead = false }
  function seat:setFocus(target)
    self.focus = target
    return true
  end
  function seat:characterFor(code)
    return if code == 30 then 'a' else nil
  end
  function seat:symbolFor()
    return nil
  end
  function seat:strokeFor()
    return nil
  end
  local sink = { dead = false }
  function sink:modifiers(held)
    env.sent[#env.sent + 1] = { 'modifiers', table.concat(held, '+') }
    return true
  end
  function sink:key(code, down)
    env.sent[#env.sent + 1] = { 'key', code, down }
    return true
  end
  function sink:typeText(text)
    env.sent[#env.sent + 1] = { 'text', text }
    return true
  end
  focus:setFocus(owner, { seat = seat, sink = sink })
  env.pointer = pointers:newPointer(owner, {
    seat = seat,
    vibrate = function(haptic)
      env.pulses[#env.pulses + 1] = haptic
      return true
    end,
  })
  env.board = service:new(owner)
  return env
end

local function keyWhere(board, predicate)
  for _, key in ipairs(board:keys()) do
    if predicate(key) then
      return key
    end
  end
  error 'no such key'
end

local function code(board, wanted)
  return keyWhere(board, function(key)
    return key.code == wanted
  end)
end

local function action(board, kind)
  return keyWhere(board, function(key)
    return key.action ~= nil and key.action.kind == kind
  end)
end

local function press(env, key)
  env.board:onPress(key.x + key.width / 2, key.y + key.height / 2, env.pointer)
end

test('rows place spacers, offsets, and tall keys, and a press reaches onKey with its haptic', function()
  local env = start()
  local board = env.board
  expect.equal(board.width, 5, 'the width')
  expect.equal(board.height, 3.5, 'the height')
  expect.equal(#board:keys(), 9, 'spacers are not keys')
  expect.equal(code(board, 30).legend, 'a', "a code key's legend comes from the seat")
  expect.equal(code(board, 31).x, 2.5, 'a spacer and an offset leave room')
  expect.equal(code(board, 32).height, 2, 'a tall key spans two rows')
  expect.equal(code(board, 44).y, 1, 'a row advances by its shortest key')
  expect.near(action(board, 'layer').y, 2.5, 1e-9, 'a half-height spacer and an empty row advance by their heights')
  expect.equal(action(board, 'custom').legend, 'wave', "an action key's legend")
  expect.truthy(table.isfrozen(code(board, 30).source), 'a key keeps its frozen source')

  press(env, code(board, 30))
  expect.truthy(#env.pressed == 1 and env.pressed[1].code == 30, 'onKey saw the key')
  expect.truthy(#env.pulses == 1 and env.pulses[1].strength == 0.5, "the hook's haptic reaches the pointer")
  expect.truthy(env.sent[2][1] == 'key' and env.sent[2][2] == 30 and env.sent[2][3] == true, 'the base sent the key')
  board:onPress(1.25, 0.5, env.pointer)
  expect.equal(#env.pressed, 1, 'a press on a spacer presses nothing')

  local small = env.service:new(env.owner, { rows = { { { code = 30 }, { code = 31 } } }, style = { keyUnit = 0.5 } })
  expect.truthy(small.width == 1 and small.height == 0.5, "a keyboard's own rows and style override the provider's")
  expect.raises(function()
    env.service:new(env.owner, { rows = { { { code = 30, label = 3 } } } })
  end, 'option rows%[1%]%[1%]%.label is a string', "a keyboard's own rows are checked")
  env.session:close()
end)

test('a configured lock stays and a configured latch clears after the next key', function()
  local env = start()
  expect.truthy(env.board:pressKey(42) and env.board:pressKey(29), 'the modifier keys')
  table.clear(env.sent)
  env.board:pressKey(30)
  expect.equal(env.sent[1][2], 'shift+control', 'the modifiers held for the key')
  expect.equal(table.concat(env.board:modifiers(), '+'), 'shift', 'the lock stays and the latch clears')
  env.session:close()
end)

test('action keys type text, send chords, reach the hook, show layers, and hide', function()
  local env = start()
  local board = env.board
  press(env, action(board, 'text'))
  expect.truthy(env.sent[1][1] == 'text' and env.sent[1][2] == 'hi', 'a text key types its text')
  table.clear(env.sent)
  press(env, action(board, 'chord'))
  expect.equal(env.sent[1][2], 'control+alt', 'the chord holds its modifiers')
  expect.truthy(env.sent[2][2] == 20 and env.sent[3][3] == false, 'the chord presses and releases its key')
  expect.equal(env.sent[4][2], '', 'the chord releases its modifiers')
  press(env, action(board, 'custom'))
  expect.equal(env.custom[1], 'wave', 'a custom action reaches the hook')

  press(env, action(board, 'layer'))
  expect.equal(board.layer, 'symbols', 'a layer key shows its layer')
  expect.truthy(#board:keys() == 2 and board.width == 5, "the size stays the widest layer's")
  board:setLayer 'base'
  expect.raises(function()
    board:setLayer 'emoji'
  end, nil, 'an unknown layer')
  press(env, action(board, 'hide'))
  expect.equal(board.visible, false, 'a hide key hides')
  env.session:close()
end)

test('drawKey wraps the default for every key, with the hover and held states', function()
  local env = start()
  local board = env.board
  board:onHover(code(board, 31).x + 0.5, 0.5, env.pointer)
  board:draw(env.native.events.pass)
  expect.equal(#env.drawn, 9, 'every key is drawn through the hook')
  for _, entry in ipairs(env.drawn) do
    expect.equal(entry.board, board, 'the keyboard in the state')
    expect.equal(entry.hovered, entry.key.code == 31, 'only the hovered key is hovered')
  end
  local texts = 0
  for _, call in ipairs(env.native.events.draw) do
    if call[1] == 'text' then
      texts += 1
    end
  end
  expect.equal(texts, 9, 'the base drew every legend')

  board:setLayer 'symbols'
  table.clear(env.drawn)
  board:draw(env.native.events.pass)
  expect.truthy(#env.drawn == 2 and env.drawn[1].key.code == 2, 'the shown layer is drawn')
  board:setLayer 'base'
  table.clear(env.drawn)
  board:draw(env.native.events.pass)
  for _, entry in ipairs(env.drawn) do
    if entry.key.action and entry.key.action.kind == 'layer' then
      expect.equal(entry.held, false, 'a layer key is not held while its layer is hidden')
    end
  end
  env.session:close()
end)

test('define checks what the generic validation cannot see into', function()
  expect.raises(function()
    keyboard.define { rows = { { { code = 1, action = { kind = 'hide' } } } } }
  end, 'has a code and an action', 'a key with a code and an action')
  expect.raises(function()
    keyboard.define { modifierKeys = { [42] = 'hyper' } }
  end, 'is a modifier name, not hyper', 'an unknown modifier')
end)

return test
