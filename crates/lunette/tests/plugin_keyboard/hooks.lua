-- Rows with spacers, offsets, and tall keys; action keys and layers; the
-- modifier and lock sets; and the onKey and drawKey hooks wrapping the
-- defaults, with the key-click haptic reaching the pointer that pressed.
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/keyboard'
local interaction = require '@lunette-contracts/interaction'
local keyboardModule = require '@lunette-plugins/keyboard'

vector = setmetatable({
  pack = function(x)
    return x
  end,
}, { __index = vector })

local function near(a, b)
  return math.abs(a - b) < 1e-9
end

local rows = {
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
local symbols = { { { code = 2 }, { action = { kind = 'layer', layer = 'base' }, label = 'abc' } } }

local pressed, custom, drawn = {}, {}, {}
local definition = keyboardModule.define {
  name = 'custom-keyboard',
  rows = rows,
  layers = { symbols = symbols },
  style = { keyUnit = 1, gap = 0 },
  modifierKeys = { [42] = 'shift', [29] = 'control' },
  locks = { 'shift' },
  onKey = function(board, key, pointer, base)
    pressed[#pressed + 1] = key
    pointer:vibrate { strength = 0.5, duration = 0.02 }
    local action = key.action
    if action and action.kind == 'custom' then
      custom[#custom + 1] = action.name
      return
    end
    base(board, key, pointer)
  end,
  drawKey = function(pass, key, state, base)
    drawn[#drawn + 1] = { key = key, held = state.held, hovered = state.hovered, board = state.keyboard }
    base(pass, key, state)
  end,
}
assert(definition.name == 'custom-keyboard')

-- define checks what the generic validation cannot see into, at the call.
local function rejects(expected, options)
  local ok, message = pcall(keyboardModule.define, options)
  assert(not ok, 'expected ' .. expected)
  assert(tostring(message):find(expected, 1, true), tostring(message))
end
rejects('option rows[1][1] has a code and an action', { rows = { { { code = 1, action = { kind = 'hide' } } } } })
rejects('option rows[1][1].width is a positive number, not 0', { rows = { { { code = 1, width = 0 } } } })
rejects('option rows[1][1].action.kind is hide, layer, text, chord, or custom, not paste', {
  rows = { { { action = { kind = 'paste' } } } },
})
rejects('option rows[1][1].action is a text action without its text', { rows = { { { action = { kind = 'text' } } } } })
rejects('option layers names a layer with a non-empty string other than base', { layers = { base = {} } })
rejects('option modifierKeys[42] is a modifier name, not hyper', { modifierKeys = { [42] = 'hyper' } })
rejects('option rows[1][1].action.modifiers[1] is a modifier name, not ctrl', {
  rows = { { { action = { kind = 'chord', code = 20, modifiers = { 'ctrl' } } } } },
})

local runtime = plugin.runtime()
runtime:use(require('@lunette-plugins/panels').definition, {}):enable()
runtime:use(require('@lunette-plugins/interaction').definition, {}):enable()
local provider = runtime:use(definition, {})
provider:enable()
assert(provider:state() == 'active', tostring(provider:diagnostic()))
local service, owner, pointers
runtime
  :use(
    plugin.define {
      name = 'hooks-consumer',
      requires = { keyboard = contract.capability, interaction = interaction.capability },
      init = function(ctx)
        service, owner, pointers = ctx:require(contract.capability), ctx, ctx:require(interaction.capability)
      end,
    },
    {}
  )
  :enable()

local events = {}
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
  events[#events + 1] = { 'modifiers', table.concat(held, '+') }
  return true
end
function sink:key(code, down)
  events[#events + 1] = { 'key', code, down }
  return true
end
function sink:typeText(text)
  events[#events + 1] = { 'text', text }
  return true
end
pointers:setFocus(owner, { seat = seat, sink = sink })

local pulses = {}
local pointer = pointers:newPointer(owner, {
  seat = seat,
  vibrate = function(haptic)
    pulses[#pulses + 1] = haptic
    return true
  end,
})
local silent = pointers:newPointer(owner, {})
assert(silent:vibrate { strength = 1, duration = 1 } == false, 'a pointer given no device does not pulse')

-- Geometry: spacers take room and are not keys, `x` leaves room before a key,
-- a tall key reaches into the next row, a row advances by its shortest key,
-- and an empty row advances by one unit.
local board = service:new(owner)
assert(board.width == 5 and board.height == 3.5, board.width .. 'x' .. board.height)
local placed = board:keys()
assert(#placed == 9, #placed)
local function keyFor(predicate)
  for _, key in ipairs(placed) do
    if predicate(key) then
      return key
    end
  end
  error 'no such key'
end
local function code(wanted)
  return keyFor(function(key)
    return key.code == wanted
  end)
end
local function action(kind)
  return keyFor(function(key)
    return key.action ~= nil and key.action.kind == kind
  end)
end
assert(code(30).x == 0 and code(30).legend == 'a')
assert(code(31).x == 2.5 and code(31).y == 0, 'a spacer and an offset leave room')
assert(code(32).x == 3.5 and code(32).height == 2, 'a tall key spans two rows')
assert(code(44).y == 1 and code(44).width == 2)
assert(near(action('layer').y, 2.5), 'a half-height spacer and an empty row advance by their heights')
assert(action('layer').legend == 'sym' and action('custom').legend == 'wave' and action('text').legend == 'hi')
assert(table.isfrozen(code(30).source) and code(30).source == board:keys()[1].source, 'a key keeps its source')

local function press(key)
  board:onPress(key.x + key.width / 2, key.y + key.height / 2, pointer)
end

-- A code key sends its code, and the hook's haptic reaches the pointer.
press(code(30))
assert(#pressed == 1 and pressed[1].code == 30)
assert(#pulses == 1 and pulses[1].strength == 0.5 and pulses[1].duration == 0.02)
assert(events[2][1] == 'key' and events[2][2] == 30 and events[2][3] == true)

-- A press on a spacer presses nothing.
board:onPress(1.25, 0.5, pointer)
assert(#pressed == 1 and #pulses == 1)

-- Modifiers follow the configured sets: shift locks, control latches.
assert(board:pressKey(42) and board:pressKey(29))
table.clear(events)
board:pressKey(30)
assert(events[1][2] == 'shift+control', events[1][2])
assert(table.concat(board:modifiers(), '+') == 'shift', 'the lock stays and the latch clears')
board:pressKey(42)

-- Action keys.
table.clear(events)
press(action 'text')
assert(events[1][1] == 'text' and events[1][2] == 'hi')
table.clear(events)
press(action 'chord')
assert(events[1][2] == 'control+alt' and events[2][2] == 20 and events[3][3] == false and events[4][2] == '')
press(action 'custom')
assert(custom[1] == 'wave', 'a custom action reaches the hook')

-- The hover state reaches drawKey, and only the keyboard's own keys are drawn.
board:onHover(code(31).x + 0.5, 0.5, pointer)
local pass = {}
local calls = {}
for _, name in ipairs { 'setColor', 'plane', 'text' } do
  pass[name] = function(_, ...)
    calls[#calls + 1] = { name, ... }
  end
end
board:draw(pass)
assert(#drawn == 9)
for _, entry in ipairs(drawn) do
  assert(entry.board == board)
  assert(entry.hovered == (entry.key.code == 31), 'only the hovered key is hovered')
end
local texts = 0
for _, call in ipairs(calls) do
  if call[1] == 'text' then
    texts += 1
  end
end
assert(texts == 9, 'the base drew every legend')

-- A layer key shows its layer, held while it shows; the size stays the
-- widest layer's.
press(action 'layer')
assert(board.layer == 'symbols' and #board:keys() == 2 and board.width == 5)
table.clear(drawn)
board:draw(pass)
assert(#drawn == 2 and drawn[2].held == false and drawn[1].key.code == 2)
board:setLayer 'base'
table.clear(drawn)
board:draw(pass)
local layerKey
for _, entry in ipairs(drawn) do
  if entry.key.action and entry.key.action.kind == 'layer' then
    layerKey = entry
  end
end
assert(layerKey and layerKey.held == false, 'a layer key is not held while its layer is hidden')
assert(not pcall(board.setLayer, board, 'emoji'), 'an unknown layer raises')

-- hide hides.
placed = board:keys()
press(action 'hide')
assert(board.visible == false)

-- A keyboard's own rows and style override the provider's, checked the same way.
local small = service:new(owner, { rows = { { { code = 30 }, { code = 31 } } }, style = { keyUnit = 0.5 } })
assert(small.width == 1 and small.height == 0.5 and #small:keys() == 2)
local ok, message = pcall(service.new, service, owner, { rows = { { { code = 30, label = 3 } } } })
assert(not ok and tostring(message):find('option rows[1][1].label is a string', 1, true), tostring(message))

runtime:close()
