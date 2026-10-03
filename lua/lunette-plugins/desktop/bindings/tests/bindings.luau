-- Covers the desktop bindings consumer: a configured reload chord replaces F5 rather than adding to it.
local testing = require '@testing'
local expect = testing.expect
local bindingsContract = require '@lunette-contracts/bindings'

local test = testing.suite()

-- Whether `chords` holds the chord of `key` with exactly `modifiers`, in that order.
local function holds(chords, key, modifiers)
  for _, chord in ipairs(chords) do
    if chord.key == key and table.concat(chord.modifiers, '+') == table.concat(modifiers, '+') then
      return true
    end
  end
  return false
end

test('the configured reload chord replaces F5', function()
  local session = testing.boot {
    'frame',
    'bindings',
    {
      id = 'desktop/bindings',
      definition = require '@lunette-plugins/desktop/bindings',
      config = { reload = { key = 'r', modifiers = { 'control' } } },
    },
  }
  local bindings = session:observe(bindingsContract.capability).service
  local chords = bindings:chords()
  expect.equal(#chords, 1, 'the chords bound')
  expect.truthy(holds(chords, 'r', { 'control' }), 'the configured reload chord')
  expect.falsy(holds(chords, 'f5', {}), 'the default reload chord')
  expect.falsy(bindings:dispatch { key = 'f5', modifiers = {}, isRepeat = false }, 'a press of F5 is consumed')
  session:close()
end)

return test
