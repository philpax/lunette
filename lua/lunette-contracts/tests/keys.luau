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

test('every LÖVR translation is a named key or a modifier', function()
  local named = {}
  for _, code in pairs(keys.CODES) do
    named[code] = true
  end
  for name, code in pairs(keys.FROM_LOVR) do
    expect.truthy(named[code], "LÖVR's '" .. name .. "' is a named key")
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
  expect.equal(keys.physicalNativePolicy(keys.CODES.a, {}), 'text', 'letter input waits for committed native text')
  expect.equal(keys.physicalNativePolicy(keys.CODES.enter, {}), 'activation', 'Enter is a control activation')
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

test('physical snapshots accept a closed plain table of six booleans and reject anything else', function()
  local copied = keys.snapshotPhysicalModifiers(snapshot { numLock = true })
  expect.truthy(copied.numLock, 'the snapshot keeps the flag')
  expect.equal(keys.validatePhysicalModifiers(copied), nil, 'the snapshot remains valid')
  local invalid = snapshot { rightAlt = true }
  expect.truthy(keys.validatePhysicalModifiers(invalid), 'an unknown flag is rejected')
  expect.falsy(pcall(keys.snapshotPhysicalModifiers, invalid), 'invalid flags cannot become a snapshot')
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
      expect.equal(keys.physicalNativePolicy(code, { 'control' }, flags), 'activation', name .. ' command chord')
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
