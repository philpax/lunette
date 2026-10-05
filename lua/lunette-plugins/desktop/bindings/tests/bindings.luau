local testing = require '@testing'
local expect = testing.expect
local bindingsContract = require '@lunette-contracts/bindings'

local test = testing.suite()

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

test('a partial reload object retains its default key and replaces modifiers', function()
  local session = testing.boot {
    'frame',
    'bindings',
    {
      id = 'desktop/bindings',
      definition = require '@lunette-plugins/desktop/bindings',
      config = { reload = { modifiers = { 'alt' } } },
    },
  }
  local bindings = session:observe(bindingsContract.capability).service
  expect.truthy(holds(bindings:chords(), 'f5', { 'alt' }), 'the default key with configured modifiers')
  session:close()
end)

test('the key descriptor accepts declared families and rejects unsupported names', function()
  local key = require('@lunette-plugins/desktop/bindings/config').key
  for _, name in ipairs { 'a', '9', 'f1', 'f12', 'kp7', 'kpenter', '\\', 'rctrl' } do
    expect.equal(key.parse(name), name, 'the supported key ' .. name)
  end
  for _, name in ipairs { '', 'f0', 'f13', 'f01', 'kp10', 'unknown' } do
    local accepted = pcall(key.parse, name)
    expect.falsy(accepted, 'the unsupported key ' .. name)
  end
end)

return test
