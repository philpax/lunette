-- Covers lua/lunette-contracts/keys.luau: the policy it adds agrees with the runtime's names and codes.

local testing = require '@testing'
local expect = testing.expect

local lunette = require '@lunette'
local keys = require '@lunette-contracts/keys'

local test = testing.suite()

local function isModifierName(name)
  return table.find(keys.MODIFIER_ORDER, name) ~= nil
end

test('the codes are the runtime codes', function()
  local fresh = lunette.keyCodes()
  local count = 0
  for name, code in pairs(fresh) do
    expect.equal(keys.CODES[name], code, name)
    count += 1
  end
  expect.truthy(count > 0, 'the runtime names keys')
  expect.equal(keys.CODES.leftShift, 42, 'the left shift is evdev 42')
  expect.equal(keys.CODES.capsLock, 58, 'caps lock is evdev 58')
end)

test('the vocabulary tables are frozen', function()
  expect.truthy(table.isfrozen(keys.CODES), 'the codes')
  expect.truthy(table.isfrozen(keys.MODIFIER_KEYS), 'the modifier keys')
  expect.truthy(table.isfrozen(keys.LOCKS), 'the locks')
  expect.truthy(table.isfrozen(keys.MODIFIER_ORDER), 'the modifier order')
  expect.truthy(table.isfrozen(keys.FROM_LOVR), 'the LÖVR keys')
  expect.truthy(table.isfrozen(keys.LOVR_MODIFIERS), 'the LÖVR modifiers')
end)

test('every modifier key is a named key and names a modifier the native surface takes', function()
  local named = {}
  for _, code in pairs(keys.CODES) do
    named[code] = true
  end
  for code, name in pairs(keys.MODIFIER_KEYS) do
    expect.truthy(named[code], 'keycode ' .. code .. ' is a named key')
    expect.truthy(isModifierName(name), 'keycode ' .. code .. " names '" .. name .. "'")
  end
end)

test('every lock is a modifier name', function()
  for name in pairs(keys.LOCKS) do
    expect.truthy(isModifierName(name), "the lock '" .. name .. "'")
  end
  expect.truthy(keys.LOCKS.capsLock, 'caps lock stays on until pressed again')
  expect.falsy(keys.LOCKS.shift, 'shift clears after the next key')
end)

test('the keys that come in pairs name the same modifier', function()
  -- Left and right shift are different keycodes and the same modifier. If
  -- the right shift named a different modifier, half the capital letters
  -- would come out lowercase.
  local codes = keys.CODES
  expect.equal(keys.MODIFIER_KEYS[codes.leftShift], 'shift', 'the left shift')
  expect.equal(keys.MODIFIER_KEYS[codes.rightShift], 'shift', 'the right shift')
  expect.equal(keys.MODIFIER_KEYS[codes.leftCtrl], 'control', 'the left control')
  expect.equal(keys.MODIFIER_KEYS[codes.rightCtrl], 'control', 'the right control')
end)

test('every LÖVR translation is a named key or a modifier', function()
  local named = {}
  for _, code in pairs(keys.CODES) do
    named[code] = true
  end
  for name, code in pairs(keys.FROM_LOVR) do
    expect.truthy(named[code], "LÖVR's '" .. name .. "' is a named key")
  end
  for _, entry in ipairs(keys.LOVR_MODIFIERS) do
    expect.truthy(isModifierName(entry.modifier), "the LÖVR modifier '" .. entry.modifier .. "'")
    expect.truthy(#entry.keys > 0, "the keys holding '" .. entry.modifier .. "'")
  end
end)

return test
