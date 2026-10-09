local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local keyboardContract = require '@lunette-contracts/keyboard'
local focusContract = require '@lunette-contracts/focus'

local test = testing.suite()

local function start()
  testing.native()
  local env = { session = testing.start { 'theme', 'focus', 'keyboard' } }
  env.consumer = env.session:use(adapter.define {
    name = 'keyboard-routing-test',
    requires = { keyboardContract.capability, focusContract.capability },
    init = function(context)
      env.owner = context
      env.service, env.focus = context:require(keyboardContract.capability), context:require(focusContract.capability)
    end,
  })
  return env
end

local function nativeTarget()
  local sent = {}
  local seat = { id = 1, dead = false }
  function seat:characterFor(code, held)
    if code == 30 then
      return if table.find(held, 'shift') then 'Q' else 'q'
    end
    return nil
  end
  function seat:symbolFor()
    return 123
  end
  function seat:strokeFor(text)
    return if text == 'q' then { keycode = 30, modifiers = {} } else nil
  end
  function seat:setFocus(target)
    self.focus = target
    return true
  end
  local sink = { id = 1, domain = 'window', dead = false }
  function sink:setModifiers(held)
    sent[#sent + 1] = { 'modifiers', table.clone(held) }
    return true
  end
  function sink:key(code, pressed)
    sent[#sent + 1] = { 'key', code, pressed }
    return true
  end
  function sink:typeText(text)
    sent[#sent + 1] = { 'text', text }
    return true
  end
  return seat, sink, sent
end

local function localTarget(env, accepts)
  local received = { keys = {}, texts = {} }
  local target = env.focus:register(env.owner, {
    kind = 'local',
    wantsKeyboard = true,
    receiver = {
      key = function(event)
        received.keys[#received.keys + 1] = event
        return accepts
      end,
      text = function(text)
        received.texts[#received.texts + 1] = text
        return accepts
      end,
    },
  })
  return target, received
end

test('the keyboard types into a focused native sink, and its owner unloading ends it and the focus', function()
  local env = start()
  local seat, sink, sent = nativeTarget()
  env.focus:register(env.owner, { kind = 'native', seat = seat, sink = sink }):focus()
  local board = env.service:new(env.owner)
  local q
  for _, key in board:keys() do
    if key.code == 30 then
      q = key
    end
  end
  expect.equal(q.legend, 'q', "a legend comes from the focused seat's layout")

  board:pressKey(42)
  board:pressKey(30)
  expect.equal(sent[1][2][1], 'shift', 'shift latches for the next key')
  expect.truthy(sent[2][3] == true and sent[3][3] == false, 'the key is pressed and released')
  expect.equal(#board:modifiers(), 0, 'the latch clears')

  table.clear(sent)
  expect.falsy(board:typeText 'qü', 'unrepresentable window text is refused')
  expect.truthy(sent[2][1] == 'key' and sent[2][2] == 30, 'the keymap strokes the representable prefix')

  env.consumer:disable()
  expect.truthy(board.dead, 'the keyboard ends with its owner')
  expect.equal(seat.focus, nil, 'the focus the owner held ends with it')
  env.session:close()
end)

test('a local route receives keys and committed text, and a focus change clears modifiers', function()
  local env = start()
  local first, received = localTarget(env, true)
  first:focus()
  local board = env.service:new(env.owner)
  expect.truthy(board:pressKey(30))
  expect.equal(received.keys[1].code, 30)
  expect.equal(#received.texts, 0, 'a key legend is not text input')
  expect.truthy(board:typeText 'committed UTF-8')
  expect.equal(received.texts[1], 'committed UTF-8')

  board:pressKey(42)
  board:pressKey(58)
  expect.equal(table.concat(board:modifiers(), '+'), 'shift+capsLock')
  local second, other = localTarget(env, true)
  second:focus()
  expect.equal(#board:modifiers(), 0, 'a route change clears locks and latches')
  board:pressKey(30)
  expect.equal(#other.keys[1].modifiers, 0, 'the next route receives no old modifiers')
  env.session:close()
end)

test('a refused activation consumes a latch but keeps a lock', function()
  local env = start()
  local target, received = localTarget(env, false)
  target:focus()
  local board = env.service:new(env.owner)
  board:pressKey(42)
  board:pressKey(58)
  expect.falsy(board:pressKey(30))
  expect.equal(table.concat(received.keys[1].modifiers, '+'), 'shift+capsLock')
  expect.equal(table.concat(board:modifiers(), '+'), 'capsLock')
  env.session:close()
end)

test('visibility notifications name actual transitions and end with destruction', function()
  local env = start()
  local changes = {}
  local board
  board = env.service:new(env.owner, {
    onVisibilityChanged = function(change)
      expect.equal(board.visible, change.visible, 'visibility is committed before notification')
      changes[#changes + 1] = change.reason
    end,
  })
  board:setVisible(true)
  board:setVisible(false)
  board:setVisible(false)
  board:setVisible(true)
  env.consumer:disable()
  board:setVisible(true)
  expect.equal(table.concat(changes, ','), 'hide,show,destroy', 'unchanged and posthumous calls notify nothing')
  expect.equal(#env.service:inspect().registrations, 0)
  env.session:close()
end)

return test
