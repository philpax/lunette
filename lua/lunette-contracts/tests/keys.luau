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

test('every supported LÖVR key has an explicit evdev activation', function()
  local names = {
    'a',
    'b',
    'c',
    'd',
    'e',
    'f',
    'g',
    'h',
    'i',
    'j',
    'k',
    'l',
    'm',
    'n',
    'o',
    'p',
    'q',
    'r',
    's',
    't',
    'u',
    'v',
    'w',
    'x',
    'y',
    'z',
    '0',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    'space',
    'return',
    'tab',
    'escape',
    'backspace',
    'up',
    'down',
    'left',
    'right',
    'home',
    'end',
    'pageup',
    'pagedown',
    'insert',
    'delete',
    'f1',
    'f2',
    'f3',
    'f4',
    'f5',
    'f6',
    'f7',
    'f8',
    'f9',
    'f10',
    'f11',
    'f12',
    '`',
    '-',
    '=',
    '[',
    ']',
    '\\',
    ';',
    "'",
    ',',
    '.',
    '/',
    'kp0',
    'kp1',
    'kp2',
    'kp3',
    'kp4',
    'kp5',
    'kp6',
    'kp7',
    'kp8',
    'kp9',
    'kp.',
    'kp/',
    'kp*',
    'kp-',
    'kp+',
    'kpenter',
    'kp=',
    'lctrl',
    'lshift',
    'lalt',
    'lgui',
    'rctrl',
    'rshift',
    'ralt',
    'rgui',
    'capslock',
    'scrolllock',
    'numlock',
  }
  local count = 0
  for _ in pairs(keys.FROM_LOVR) do
    count += 1
  end
  expect.equal(count, #names, 'the closed LÖVR enum is covered once')
  for _, name in ipairs(names) do
    expect.truthy(keys.FROM_LOVR[name], name .. ' maps to evdev')
  end
  expect.equal(keys.FROM_LOVR.a, 30, 'A is not a platform scancode')
  expect.equal(keys.FROM_LOVR.kpenter, 96, 'keypad Enter is distinct from Enter')
  expect.equal(keys.FROM_LOVR.ralt, 100, 'right Alt is distinct from left Alt')
  expect.truthy(keys.PRINTABLE_CODES[keys.CODES.a], 'letter input waits for committed native text')
  expect.falsy(keys.PRINTABLE_CODES[keys.CODES.enter], 'Enter is a control activation')
end)

test('physical modifiers include Shift and distinguish right Alt from command Alt', function()
  local held = { lshift = true, ralt = true }
  local function query(name)
    return held[name] == true
  end
  expect.equal(table.concat(keys.heldModifiers { isDown = query, shift = true }, ','), 'mod5,shift', 'AltGr and Shift')
  held.lalt = true
  expect.equal(
    table.concat(keys.heldModifiers { isDown = query, shift = true }, ','),
    'alt,mod5,shift',
    'both Alt keys'
  )
end)

local function snapshot(fields)
  local value = { shift = false, control = false, alt = false, super = false, capsLock = false, numLock = false }
  for name, enabled in fields or {} do
    value[name] = enabled
  end
  return value
end

test('physical snapshots require a closed plain table of all six booleans and copy immutably', function()
  local value = snapshot { numLock = true }
  local copied = keys.snapshotPhysicalModifiers(value)
  expect.truthy(table.isfrozen(copied), 'the host snapshot is frozen')
  expect.truthy(copied ~= value, 'the callback table is not retained')
  value.numLock = false
  expect.truthy(copied.numLock, 'later callback table changes cannot alter the event')
  expect.raises(function()
    copied.shift = true
  end, 'readonly', 'event flags cannot be changed')
  local malformed = {
    false,
    {},
    snapshot { shift = 1 },
    snapshot { numLock = 'on' },
    snapshot { rightAlt = true },
    setmetatable(snapshot(), {}),
  }
  local sparse = snapshot()
  sparse.capsLock = nil
  malformed[#malformed + 1] = sparse
  for _, invalid in malformed do
    expect.truthy(keys.validatePhysicalModifiers(invalid), 'invalid host flags are rejected')
    expect.falsy(pcall(keys.snapshotPhysicalModifiers, invalid), 'invalid flags cannot become a snapshot')
  end
  expect.equal(keys.validatePhysicalModifiers(copied), nil, 'frozen plain flags remain valid')
end)

test('PC keypad policy covers every digit and decimal for the complete NumLock and Shift matrix', function()
  local cases = {
    { numLock = false, shift = false, expected = 'activation' },
    { numLock = false, shift = true, expected = 'activation' },
    { numLock = true, shift = false, expected = 'text' },
    { numLock = true, shift = true, expected = 'activation' },
  }
  for _, name in { 'kp0', 'kp1', 'kp2', 'kp3', 'kp4', 'kp5', 'kp6', 'kp7', 'kp8', 'kp9', 'kp.' } do
    local code = keys.FROM_LOVR[name]
    expect.equal(keys.physicalNativePolicy(code, {}, nil), 'unavailable', name .. ' needs host flags')
    for _, case in cases do
      local flags = snapshot { numLock = case.numLock, shift = case.shift }
      expect.equal(keys.physicalNativePolicy(code, {}, flags), case.expected, name .. ' PC mode')
      expect.equal(keys.physicalNativePolicy(code, { 'Control' }, flags), 'activation', name .. ' command chord')
    end
  end
  expect.equal(keys.physicalNativePolicy(keys.CODES.left, {}, nil), 'activation', 'ordinary navigation')
  expect.equal(keys.physicalNativePolicy(keys.CODES.keypadPlus, {}, nil), 'text', 'keypad operator is printable')
end)

test('host flags replace later modifiers except for the existing sided Alt distinction', function()
  local queried = {}
  local function held(name)
    queried[#queried + 1] = name
    return name == 'ralt'
  end
  local names = keys.physicalModifierNames(snapshot { alt = true, shift = true, numLock = true }, held)
  expect.equal(table.concat(names, ','), 'mod5,shift,numLock', 'right Alt remains level three')
  for _, name in queried do
    expect.truthy(name == 'ralt' or name == 'lalt', 'only sided Alt queries remain')
  end
  names = keys.physicalActivationModifiers(snapshot(), { 'control', 'shift', 'logo', 'capsLock', 'numLock' })
  expect.equal(#names, 0, 'later flags cannot replace host-event flags')
  names = keys.physicalActivationModifiers(snapshot { control = true, super = true, capsLock = true }, {})
  expect.equal(table.concat(names, ','), 'control,logo,capsLock', 'event commands and locks')
end)

return test
