local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local keyboardContract = require '@lunette-contracts/keyboard'
local interactionContract = require '@lunette-contracts/interaction'
local focusContract = require '@lunette-contracts/focus'
local keyboard = require '../'
local theme = require '@lunette-contracts/theme'

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
  { { code = 42 }, { code = 29 } },
}
local SYMBOLS = { { { code = 2 }, { action = { kind = 'layer', layer = 'base' }, label = 'abc' } } }

type Sent = { string | number | boolean }
type Environment = {
  native: testing.Native,
  pressed: { keyboard.RenderedKey },
  custom: { string },
  drawn: {
    {
      key: keyboard.RenderedKey,
      hovered: boolean,
      board: keyboard.Board,
      style: { read font: Font, read gap: number, read legendHeight: number, read keyColor: { read [number]: number } },
    }
  },
  sent: { Sent },
  pulses: { interactionContract.Haptic },
  session: testing.Session?,
  service: keyboardContract.Service?,
  owner: adapter.Context?,
  pointer: interactionContract.Pointer?,
  board: keyboard.Board?,
}
type Sink = {
  monitor: { read id: number },
  domain: 'host',
  dead: boolean,
  setModifiers: (Sink, { string }) -> boolean,
  key: (Sink, number, boolean) -> boolean,
  typeText: (Sink, string) -> boolean,
}
type Seat = {
  id: number,
  dead: boolean,
  focus: Sink?,
  setFocus: (Seat, Sink?) -> boolean,
  characterFor: (Seat, number) -> string?,
  symbolFor: (Seat) -> nil,
  strokeFor: (Seat) -> nil,
}

local function start(): Environment
  local env: Environment = { native = testing.native(), pressed = {}, custom = {}, drawn = {}, sent = {}, pulses = {} }
  local definition = keyboard.define {
    name = 'custom-keyboard',
    rows = ROWS,
    layers = { symbols = SYMBOLS },
    style = { keyUnit = 1, gap = 0, keyRadius = 0.003 },
    modifierKeys = { [42] = 'shift', [29] = 'control' },
    locks = { 'shift' },
    onKey = function(board: keyboard.Board, key: keyboard.RenderedKey, pointer: keyboard.Pointer, base: keyboard.Press)
      env.pressed[#env.pressed + 1] = key
      pointer:vibrate { strength = 0.5, duration = 0.02 }
      local action = key.action
      if action and action.kind == 'custom' then
        env.custom[#env.custom + 1] = action.name
        return
      end
      base(board, key, pointer)
    end,
    drawKey = function(pass: Pass, key: keyboard.RenderedKey, state: keyboard.KeyState, base: keyboard.Paint)
      env.drawn[#env.drawn + 1] = { key = key, hovered = state.hovered, board = state.keyboard, style = state.style }
      expect.equal(pass:getFont(), state.style.font, 'the hook measures with the exact leased face')
      base(pass, key, state)
    end,
  }
  env.session = testing.start { 'theme', 'drops', 'focus', 'interaction', { id = 'keyboard', definition = definition } }
  local service: keyboardContract.Service?, owner: adapter.Context?, pointers: interactionContract.Service?, focus: focusContract.Service?
  env.session:use(adapter.define {
    name = 'keyboard-options-test',
    requires = {
      keyboardContract.capability,
      interactionContract.capability,
      focusContract.capability,
    },
    init = function(context: adapter.Context)
      service, owner = context:require(keyboardContract.capability), context
      pointers, focus = context:require(interactionContract.capability), context:require(focusContract.capability)
    end,
  })
  env.service, env.owner = service, owner

  local seat: Seat = { id = 1, dead = false }
  function seat:setFocus(target: Sink?): boolean
    self.focus = target
    return true
  end
  function seat:characterFor(code: number): string?
    return if code == 30 then 'a' else nil
  end
  function seat:symbolFor(): nil
    return nil
  end
  function seat:strokeFor(): nil
    return nil
  end
  local sink = { monitor = { id = 1 }, domain = 'host', dead = false }
  function sink:setModifiers(held: { string }): boolean
    env.sent[#env.sent + 1] = { 'modifiers', table.concat(held, '+') }
    return true
  end
  function sink:key(code: number, down: boolean): boolean
    env.sent[#env.sent + 1] = { 'key', code, down }
    return true
  end
  function sink:typeText(text: string): boolean
    env.sent[#env.sent + 1] = { 'text', text }
    return true
  end
  focus:register(owner, { kind = 'native', seat = seat, sink = sink }):focus()
  env.pointer = pointers:newPointer(owner, {
    seat = seat,
    vibrate = function(haptic: interactionContract.Haptic): boolean
      env.pulses[#env.pulses + 1] = haptic
      return true
    end,
  })
  env.board = service:new(owner)
  return env
end

local function keyWhere(board: keyboard.Board, predicate: (keyboard.RenderedKey) -> boolean): keyboard.RenderedKey
  for _, key in ipairs(board:keys()) do
    if predicate(key) then
      return key
    end
  end
  error 'no such key'
end

local function code(board: keyboard.Board, wanted: number): keyboard.RenderedKey
  return keyWhere(board, function(key: keyboard.RenderedKey): boolean
    return key.code == wanted
  end)
end

local function action(board: keyboard.Board, kind: string): keyboard.RenderedKey
  return keyWhere(board, function(key: keyboard.RenderedKey): boolean
    return key.action ~= nil and key.action.kind == kind
  end)
end

local function pressAt(env: Environment, x: number, y: number)
  env.board:onPointer {
    kind = 'press',
    pointer = env.pointer,
    button = 'left',
    x = x,
    y = y,
    inside = true,
    captured = true,
  }
end

local function press(env: Environment, key: keyboard.RenderedKey)
  pressAt(env, key.x + key.width / 2, key.y + key.height / 2)
end

test('rows place spacers, offsets, and tall keys, and a press reaches onKey with its haptic', function()
  local env = start()
  local board = env.board
  expect.equal(board.width, 5, 'the width')
  expect.equal(board.height, 4.5, 'the height')
  expect.equal(#board:keys(), 11, 'spacers are not keys')
  expect.equal(code(board, 30).legend, 'a', "a code key's legend comes from the seat")
  expect.equal(code(board, 31).x, 2.5, 'a spacer and an offset leave room')
  expect.equal(code(board, 32).height, 2, 'a tall key spans two rows')
  expect.equal(code(board, 44).y, 1, 'a row advances by its shortest key')
  expect.near(action(board, 'layer').y, 2.5, 1e-9, 'a half-height spacer and an empty row advance by their heights')
  expect.equal(action(board, 'custom').legend, 'wave', "an action key's legend")

  press(env, code(board, 30))
  expect.truthy(#env.pressed == 1 and env.pressed[1].code == 30, 'onKey saw the key')
  expect.truthy(#env.pulses == 1 and env.pulses[1].strength == 0.5, "the hook's haptic reaches the pointer")
  expect.truthy(env.sent[2][1] == 'key' and env.sent[2][2] == 30 and env.sent[2][3] == true, 'the base sent the key')
  pressAt(env, 1.25, 0.5)
  expect.equal(#env.pressed, 1, 'a press on a spacer presses nothing')
  expect.raises(function()
    keyboard.define { rows = { { { code = 1, action = { kind = 'hide' } } } } }
  end, 'has a code and an action', 'define checks what the schema cannot see')
  env.session:close()
end)

test('modifiers lock or latch, and action keys type, send chords, reach the hook, switch layers, and hide', function()
  local env = start()
  local board = env.board
  press(env, code(board, 42))
  press(env, code(board, 29))
  table.clear(env.sent)
  press(env, code(board, 30))
  expect.equal(env.sent[1][2], 'shift+control', 'the modifiers held for the key')
  table.clear(env.sent)
  press(env, code(board, 30))
  expect.equal(env.sent[1][2], 'shift', 'the configured lock stays and the latch clears')
  press(env, code(board, 42))
  table.clear(env.sent)
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
  press(env, action(board, 'hide'))
  expect.equal(board.visible, false, 'a hide key hides')
  env.session:close()
end)

test('drawKey wraps the default for every key, with the hover state and the live theme style', function()
  local env = start()
  local board = env.board
  board:onPointer { kind = 'enter', pointer = env.pointer, x = code(board, 31).x + 0.5, y = 0.5, inside = true }
  board:draw(env.native.events.pass)
  expect.equal(#env.drawn, 11, 'every key is drawn through the hook')
  for _, entry in ipairs(env.drawn) do
    expect.equal(entry.board, board, 'the keyboard in the state')
    expect.equal(entry.hovered, entry.key.code == 31, 'only the hovered key is hovered')
  end
  local observed = env.session:observe(theme.capability)
  local selection = observed.service:select(observed.context, {
    colors = { control = { 0.21, 0.22, 0.23, 1 } },
    typography = { keyboardLegendHeight = 0.02 },
    metrics = { keyboardGap = 0.01 },
  })
  table.clear(env.drawn)
  board:draw(env.native.events.pass)
  local style = env.drawn[1].style
  expect.equal(style.gap, 0, 'the provider gap wins over global metrics')
  expect.near(style.legendHeight, 0.02, 1e-9, 'an omitted provider value follows the global theme')
  expect.equal(style.keyColor[1], 0.21, 'the global palette maps the key colour')
  selection:dispose()
  env.session:close()
end)

return test
