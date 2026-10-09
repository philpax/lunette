-- Covers lua/lunette-contracts/keys.luau: the vocabulary agrees with the runtime's names and codes.

local testing = require '@testing'
local expect = testing.expect

local lunette = require '@lunette'
local keys = require '@lunette-contracts/keys'

local test = testing.suite()

test('the codes are the runtime codes', function()
  local fresh = lunette.keyCodes()
  local count = 0
  for name, code in pairs(fresh) do
    expect.equal(keys.CODES[name], code, name)
    count += 1
  end
  expect.truthy(count > 0, 'the runtime names keys')
end)

test('every modifier key is a named key holding a runtime modifier', function()
  local named = {}
  for _, code in pairs(keys.CODES) do
    named[code] = true
  end
  for code, name in pairs(keys.MODIFIER_KEYS) do
    expect.truthy(named[code], 'keycode ' .. code .. ' is a named key')
    expect.truthy(table.find(lunette.modifierNames(), name), 'keycode ' .. code .. " names '" .. name .. "'")
  end
end)

test('control, logo, and left Alt make a command chord, and Shift and AltGr do not', function()
  expect.truthy(keys.commandChord { 'shift', 'logo' }, 'logo')
  expect.truthy(keys.commandChord { 'alt' }, 'left Alt')
  expect.falsy(keys.commandChord { 'shift', 'mod5', 'capsLock' }, 'level and lock modifiers')
end)

return test
