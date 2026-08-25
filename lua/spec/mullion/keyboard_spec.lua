-- Covers lua/mullion/keyboard.lua.
--
-- The seat is a fake carrying a small invented keymap. The real one answers
-- from libxkbcommon, and a spec asserting what it said would be asserting Phase
-- 5's work rather than this module's — and would say nothing about the thing
-- worth checking here, which is that the legends and the keycodes come from
-- whatever keymap the seat has rather than from a table of this module's own.
--
-- So the fake layout is deliberately not QWERTY. A keyboard that hardcoded one
-- would pass every case that asked "is this key an A" and fail every case here.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local interaction = require '@mullion/interaction'
local keyboard = require '@mullion/keyboard'
local keycodes = require '@mullion/keycodes'
local fixture = require '@spec/mullion/panel/fixture'

local spec = suite.new 'mullion.keyboard'

local poseAt = fixture.poseAt
local newSink = fixture.newSink
local newPass = fixture.newPass
local sequence = fixture.sequence
local lastCall = fixture.lastCall
local TOLERANCE = fixture.TOLERANCE

-- The keycodes the invented layout below binds. Physical positions, which is
-- what an evdev keycode is: the middle row's first three keys and the number
-- row's first key.
local A_KEY = 30
local S_KEY = 31
local D_KEY = 32
local ONE_KEY = 2

-- A layout in which those four keys type something no real layout puts there,
-- so that a legend copied from a hardcoded QWERTY table would be visibly wrong.
local LAYOUT = {
  [A_KEY] = { plain = 'q', shifted = 'Q' },
  [S_KEY] = { plain = 'w', shifted = 'W' },
  [D_KEY] = { plain = 'é', shifted = 'É' },
  [ONE_KEY] = { plain = '7', shifted = '&' },
}

-- Whether a modifier array holds `name`.
local function holds(modifiers, name)
  for _, held in ipairs(modifiers or {}) do
    if held == name then
      return true
    end
  end
  return false
end

-- A seat answering from LAYOUT, recording what it was told.
local function newSeat()
  local seat = { focused = {}, dead = false }

  function seat:setFocus(sink)
    self.focused[#self.focused + 1] = sink
    return true
  end

  function seat:characterFor(code, modifiers)
    local binding = LAYOUT[code]
    if not binding then
      return nil
    end
    return holds(modifiers, 'shift') and binding.shifted or binding.plain
  end

  -- A keysym for every physical key, as a real keymap has: most positions bind
  -- something even when it types no text.
  function seat:symbolFor(code)
    return 0xff00 + code
  end

  -- The reverse lookup, over the same table, preferring the unshifted binding
  -- as the real one prefers the fewest modifiers.
  function seat:strokeFor(character)
    for code, binding in pairs(LAYOUT) do
      if binding.plain == character then
        return { keycode = code, modifiers = {} }
      end
    end
    for code, binding in pairs(LAYOUT) do
      if binding.shifted == character then
        return { keycode = code, modifiers = { 'shift' } }
      end
    end
    return nil
  end

  return seat
end

-- A keyboard over a seat and a sink of this case's own, so that a case does not
-- depend on what the last one clicked.
local function newKeyboard(options)
  options = options or {}
  local seat = options.seat or newSeat()
  local sink = options.sink or newSink()
  local created = keyboard.new {
    pose = options.pose or poseAt(0, 1, -1),
    target = function()
      return seat, sink
    end,
  }
  return created, seat, sink
end

-- Starts a case with nothing left over.
local function fresh()
  keyboard.teardown()
  interaction.teardown()
end

-- The key of a given keycode, out of what `keys` produced.
local function keyFor(keys, code)
  for _, key in ipairs(keys) do
    if key.code == code then
      return key
    end
  end
  return nil
end

spec('the legends come from the keymap and not from a table of our own', function()
  fresh()
  local created = newKeyboard()

  local keys = created:keys()
  expect.equal(keyFor(keys, A_KEY).legend, 'q', "the first home-row key's legend")
  expect.equal(keyFor(keys, ONE_KEY).legend, '7', "the first number-row key's legend")
end)

spec('a held shift changes the legends', function()
  fresh()
  local created = newKeyboard()

  created:toggleModifier 'shift'

  expect.equal(keyFor(created:keys(), A_KEY).legend, 'Q', 'the legend under shift')
end)

spec('a key with no binding falls back to its own label', function()
  fresh()
  local created = newKeyboard()

  -- Space is in the matrix and not in the invented layout, and it carries a
  -- label because no character would read as one.
  local labelled
  for _, key in ipairs(created:keys()) do
    if key.code == keycodes.SPACE then
      labelled = key
    end
  end
  expect.truthy(labelled, 'the space key')
  expect.truthy(#labelled.legend > 0, "the space key's legend")
end)

spec('pressing a key sends the keycode the layout has there', function()
  fresh()
  local created, seat, sink = newKeyboard()

  created:pressKey(A_KEY)

  expect.equal(sequence(sink), 'modifiers,key,key', 'what the sink was told')
  local pressed = sink.calls[2]
  expect.equal(pressed.arguments[1], A_KEY, 'the keycode')
  expect.equal(pressed.arguments[2], true, 'pressed')
  expect.equal(pressed.arguments[3], seat, 'the seat the event was addressed to')
  expect.equal(sink.calls[3].arguments[2], false, 'released')
end)

spec('a sticky modifier applies to the next key and then clears', function()
  fresh()
  local created, _, sink = newKeyboard()

  created:pressKey(keycodes.SHIFT)
  expect.truthy(holds(created:modifiers(), 'shift'), 'shift after pressing it')
  expect.equal(#sink.calls, 0, 'what a modifier key sent')

  created:pressKey(A_KEY)

  expect.truthy(holds(sink.calls[1].arguments[1], 'shift'), 'the modifiers the key was sent under')
  expect.falsy(holds(created:modifiers(), 'shift'), 'shift after the key')
  -- The client is told the modifiers went, or it holds shift for everything
  -- typed afterwards.
  expect.equal(sequence(sink), 'modifiers,key,key,modifiers', 'what the sink was told')
  expect.falsy(holds(sink.calls[4].arguments[1], 'shift'), 'the modifiers afterwards')
end)

spec('a lock stays on across keys', function()
  fresh()
  local created, _, sink = newKeyboard()

  created:pressKey(keycodes.CAPS_LOCK)
  created:pressKey(A_KEY)

  expect.truthy(holds(created:modifiers(), 'capsLock'), 'the lock after a key')
  expect.equal(sequence(sink), 'modifiers,key,key', 'what the sink was told')
end)

spec('pressing a lock twice turns it off', function()
  fresh()
  local created = newKeyboard()

  created:pressKey(keycodes.CAPS_LOCK)
  created:pressKey(keycodes.CAPS_LOCK)

  expect.falsy(holds(created:modifiers(), 'capsLock'), 'the lock')
end)

spec('pressing a key with nothing focused sends nothing', function()
  fresh()
  local created = keyboard.new { pose = poseAt(0, 1, -1) }

  expect.falsy(created:pressKey(A_KEY), 'the press')
end)

spec('text the layout can type goes down the ordinary path', function()
  fresh()
  local created, seat, sink = newKeyboard()

  created:typeText 'qw'

  expect.equal(sequence(sink), 'modifiers,key,key,modifiers,key,key,modifiers', 'what was sent')
  expect.equal(sink.calls[2].arguments[1], A_KEY, 'the first keycode')
  expect.equal(sink.calls[5].arguments[1], S_KEY, 'the second keycode')
  expect.equal(sink.calls[2].arguments[3], seat, 'the seat the event was addressed to')
end)

spec('a character needing a modifier is sent with it', function()
  fresh()
  local created, _, sink = newKeyboard()

  created:typeText 'Q'

  expect.truthy(holds(sink.calls[1].arguments[1], 'shift'), 'the modifiers')
  expect.equal(sink.calls[2].arguments[1], A_KEY, 'the keycode')
end)

spec('a character the layout cannot express goes to typeText', function()
  fresh()
  local created, seat, sink = newKeyboard()

  created:typeText 'ü'

  local call = lastCall(sink, 'typeText')
  expect.truthy(call, 'a typeText call')
  expect.equal(call.arguments[1], 'ü', 'the text')
  expect.equal(call.arguments[2], seat, 'the seat the text was addressed to')
  expect.falsy(lastCall(sink, 'key'), 'a key call')
end)

spec('a run of characters the layout cannot express goes in one call', function()
  fresh()
  local created, _, sink = newKeyboard()

  -- One keymap upload rather than three. docs/lua-api.md says typeText
  -- generates a keymap, uploads it, types, and puts the client's own back, so
  -- a call per character would swap the client's keymap three times.
  created:typeText 'üöß'

  local calls = 0
  for _, call in ipairs(sink.calls) do
    if call.name == 'typeText' then
      calls = calls + 1
    end
  end
  expect.equal(calls, 1, 'typeText calls')
  expect.equal(lastCall(sink, 'typeText').arguments[1], 'üöß', 'the text')
end)

spec('text mixing the two keeps its order', function()
  fresh()
  local created, _, sink = newKeyboard()

  created:typeText 'qüw'

  local order = {}
  for _, call in ipairs(sink.calls) do
    if call.name == 'key' and call.arguments[2] then
      order[#order + 1] = call.arguments[1]
    elseif call.name == 'typeText' then
      order[#order + 1] = call.arguments[1]
    end
  end
  expect.equal(#order, 3, 'the things sent')
  expect.equal(order[1], A_KEY, 'the first')
  expect.equal(order[2], 'ü', 'the second')
  expect.equal(order[3], S_KEY, 'the third')
end)

spec('a multi-byte character the layout does bind is one stroke', function()
  fresh()
  local created, _, sink = newKeyboard()

  -- The invented layout puts é on a key, so this must not be split into bytes
  -- and must not be routed to typeText.
  created:typeText 'é'

  expect.equal(sequence(sink), 'modifiers,key,key,modifiers', 'what was sent')
  expect.equal(sink.calls[2].arguments[1], D_KEY, 'the keycode')
end)

spec('typing with nothing focused sends nothing', function()
  fresh()
  local created = keyboard.new { pose = poseAt(0, 1, -1) }

  expect.falsy(created:typeText 'q', 'the typing')
end)

spec('a ray hits the key it is pointed at', function()
  fresh()
  local created = newKeyboard { pose = poseAt(0, 0, -1) }

  local wanted = keyFor(created:keys(), A_KEY)
  -- The key's centre, in the keyboard's own plane: its geometry runs from the
  -- top-left with y downwards, and the plane's y runs upwards from the middle.
  local x = wanted.x + wanted.width / 2 - created.width / 2
  local y = created.height / 2 - (wanted.y + wanted.height / 2)

  local hit = created:hit(vector.pack(x, y, 0), vector.pack(0, 0, -1))

  expect.truthy(hit, 'a hit')
  expect.equal(hit.code, A_KEY, 'the key hit')
end)

spec('a ray past the edge of the keyboard hits nothing', function()
  fresh()
  local created = newKeyboard { pose = poseAt(0, 0, -1) }

  expect.falsy(created:hit(vector.pack(created.width, 0, 0), vector.pack(0, 0, -1)), 'a hit')
end)

spec('a ray between two keys still hits one', function()
  fresh()
  local created = newKeyboard { pose = poseAt(0, 0, -1) }

  local first = keyFor(created:keys(), A_KEY)
  -- Exactly on the boundary between this key and the next, where the drawn gap
  -- is. A laser is not precise enough for a gap to be a miss.
  local x = first.x + first.width - created.width / 2
  local y = created.height / 2 - (first.y + first.height / 2)

  local hit = created:hit(vector.pack(x, y, 0), vector.pack(0, 0, -1))

  expect.truthy(hit, 'a hit')
end)

spec('an invisible keyboard is not hit and is not drawn', function()
  fresh()
  local created = newKeyboard { pose = poseAt(0, 0, -1) }
  local pass = newPass()

  created:setVisible(false)
  created:draw(pass)

  expect.falsy(created:hit(vector.pack(0, 0, 0), vector.pack(0, 0, -1)), 'a hit')
  expect.equal(pass.planes, 0, 'planes drawn')
end)

spec('drawing puts a plane and a legend behind every key', function()
  fresh()
  local created = newKeyboard()
  local pass = newPass()

  created:draw(pass)

  local keys = #created:keys()
  expect.truthy(keys > 0, 'keys')
  -- One plane per key, and one behind the lot of them.
  expect.equal(pass.planes, keys + 1, 'planes drawn')
  expect.equal(pass.texts, keys, 'legends drawn')
end)

spec('the keyboard is as wide as its widest row', function()
  fresh()
  local created = newKeyboard()

  local widest = 0
  for _, row in ipairs(keycodes.ROWS) do
    local width = 0
    for _, entry in ipairs(row) do
      width = width + (entry.width or 1)
    end
    widest = math.max(widest, width)
  end

  expect.near(created.width, widest * keyboard.STYLE.keyUnit, TOLERANCE, 'the width')
  expect.near(created.height, #keycodes.ROWS * keyboard.STYLE.keyUnit, TOLERANCE, 'the height')
end)

spec('every key in the matrix carries a legend or a label', function()
  fresh()
  local created = newKeyboard()

  for _, key in ipairs(created:keys()) do
    expect.truthy(#key.legend > 0, 'the legend on keycode ' .. key.code)
  end
end)

spec('a key that types nothing falls back to its keysym', function()
  fresh()
  local created, seat = newKeyboard()

  -- The invented layout binds no character to the top-left key, and a real one
  -- binds a keysym to nearly every position. A blank key looks broken; the
  -- number at least says which key it is.
  local key = keyFor(created:keys(), 41)
  expect.equal(key.legend, string.format('0x%x', seat:symbolFor(41)), "the key's legend")
end)

spec('a keyboard with nothing focused draws blank legends rather than raising', function()
  fresh()
  local created = keyboard.new { pose = poseAt(0, 1, -1) }

  local key = keyFor(created:keys(), A_KEY)
  expect.equal(key.legend, '', "the key's legend")
  -- The labelled keys still have theirs: a label is this module's own and needs
  -- no keymap.
  expect.equal(keyFor(created:keys(), keycodes.SPACE).legend, 'space', 'the space legend')
end)

spec('the default target is whatever was last clicked', function()
  fresh()
  local seat, sink = newSeat(), newSink()
  local created = keyboard.new { pose = poseAt(0, 1, -1) }

  interaction.setFocus(seat, sink)
  created:pressKey(A_KEY)

  expect.equal(lastCall(sink, 'key').arguments[3], seat, 'the seat the event went to')
end)

spec('destroying a keyboard takes it out of the list', function()
  fresh()
  local created = newKeyboard()

  expect.equal(#keyboard.all(), 1, 'keyboards')
  expect.truthy(created:destroy(), 'the first destroy')
  expect.falsy(created:destroy(), 'the second destroy')
  expect.equal(#keyboard.all(), 0, 'keyboards left')
end)

spec('teardown destroys every keyboard', function()
  fresh()
  newKeyboard()
  newKeyboard()

  keyboard.teardown()

  expect.equal(#keyboard.all(), 0, 'keyboards left')
end)

spec('two pointers each keep their own highlighted key', function()
  -- One shared value would let whichever hand was read last erase the other's
  -- highlight, so only one key would ever light up with two hands aiming.
  local created = keyboard.new {}
  local keys = created:keys()

  created:setHovered(keys[1], 'left')
  created:setHovered(keys[2], 'right')

  expect.truthy(created:isHovered(keys[1].code), "the left hand's key")
  expect.truthy(created:isHovered(keys[2].code), "the right hand's key")

  created:setHovered(nil, 'left')
  expect.falsy(created:isHovered(keys[1].code), "the left hand's key after it moved off")
  expect.truthy(created:isHovered(keys[2].code), "the right hand's key to be untouched")
end)

spec('requiring the module twice leaves one teardown hook', function()
  fresh()
  local teardown = require '@mullion/teardown'

  local function hooks()
    local found = 0
    for _, name in ipairs(teardown.pending()) do
      if name == 'mullion.keyboard' then
        found = found + 1
      end
    end
    return found
  end

  local function reload()
    package.loaded['@mullion/keyboard'] = nil
    local loaded = require '@mullion/keyboard'
    package.loaded['@mullion/keyboard'] = keyboard
    return loaded
  end

  local once = reload()
  local first = hooks()
  local twice = reload()
  local second = hooks()

  expect.equal(first, 1, 'hooks after one run of the module body')
  expect.equal(second, 1, 'hooks after two')
  expect.truthy(once, 'the first require')
  expect.truthy(twice, 'the second require')
end)

return spec
