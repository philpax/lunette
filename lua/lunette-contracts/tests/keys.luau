-- Covers lua/lunette-contracts/keys.luau: the command chord classification.

local testing = require '@testing'
local expect = testing.expect

local keys = require '@lunette-contracts/keys'

local test = testing.suite()

test('control, logo, and left Alt make a command chord, and Shift and AltGr do not', function()
  expect.truthy(keys.commandChord { 'shift', 'logo' }, 'logo')
  expect.truthy(keys.commandChord { 'alt' }, 'left Alt')
  expect.falsy(keys.commandChord { 'shift', 'mod5', 'capsLock' }, 'level and lock modifiers')
end)

return test
