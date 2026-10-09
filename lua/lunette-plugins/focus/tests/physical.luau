-- Covers lua/lunette-plugins/focus/physical.luau: native delivery policy and the physical modifier snapshot.

local testing = require '@testing'
local expect = testing.expect

local keys = require '@lunette-contracts/keys'
local physical = require '@lunette-plugins/focus/physical'

local test = testing.suite()

local function snapshot(fields)
  local value = { shift = false, control = false, alt = false, logo = false, capsLock = false, numLock = false }
  for name, enabled in fields or {} do
    value[name] = enabled
  end
  return value
end

test('printable keys wait for committed text, and other keys and command chords activate', function()
  expect.equal(physical.nativePolicy(keys.CODES.a, {}), 'text', 'letter input waits for committed native text')
  expect.equal(physical.nativePolicy(keys.CODES.a, { 'control' }), 'activation', 'a command chord')
  expect.equal(physical.nativePolicy(keys.CODES.enter, {}), 'activation', 'Enter is a control activation')
  expect.equal(physical.nativePolicy(keys.CODES.left, {}, nil), 'activation', 'ordinary navigation')
  expect.equal(physical.nativePolicy(keys.CODES.keypadPlus, {}, nil), 'text', 'keypad operator is printable')
end)

test('PC keypad policy covers every digit and decimal for the complete NumLock and Shift matrix', function()
  local cases = {
    { numLock = false, shift = false, expected = 'activation' },
    { numLock = false, shift = true, expected = 'activation' },
    { numLock = true, shift = false, expected = 'text' },
    { numLock = true, shift = true, expected = 'activation' },
  }
  for _, name in { 'keypad1', 'keypadDot' } do
    local code = keys.CODES[name]
    expect.equal(physical.nativePolicy(code, {}, nil), 'unavailable', name .. ' needs host flags')
    for _, case in cases do
      local flags = snapshot { numLock = case.numLock, shift = case.shift }
      expect.equal(physical.nativePolicy(code, {}, flags), case.expected, name .. ' PC mode')
      expect.equal(physical.nativePolicy(code, { 'control' }, flags), 'activation', name .. ' command chord')
    end
  end
end)

test('physical snapshots accept a closed plain table of six booleans and reject anything else', function()
  local copied = physical.snapshot(snapshot { numLock = true })
  expect.truthy(copied.numLock, 'the snapshot keeps the flag')
  expect.equal(physical.validate(copied), nil, 'the snapshot remains valid')
  expect.truthy(physical.validate(snapshot { rightAlt = true }), 'an unknown flag is rejected')
  local hostSpelling = snapshot()
  hostSpelling.logo, hostSpelling.super = nil, false
  expect.truthy(physical.validate(hostSpelling), "LÖVR's super spelling is rejected")
end)

return test
