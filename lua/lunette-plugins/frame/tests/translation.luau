-- Covers lua/lunette-plugins/frame/translation.luau: LÖVR key names and modifiers become evdev codes and names.

local testing = require '@testing'
local expect = testing.expect

local keys = require '@lunette-contracts/keys'
local translation = require '@lunette-plugins/frame/translation'

local test = testing.suite()

local function host(fields: { [string]: boolean }?): keys.PhysicalModifiers
  local value: { [string]: boolean } =
    { shift = false, control = false, alt = false, super = false, capsLock = false, numLock = false }
  for name, enabled in fields or {} do
    value[name] = enabled
  end
  return translation.snapshot(value)
end

test('LÖVR keys translate to named evdev codes, not platform scancodes', function()
  local named: { [number]: boolean } = {}
  for _, code in pairs(keys.CODES) do
    named[code] = true
  end
  for name, code in pairs(translation.FROM_LOVR) do
    expect.truthy(named[code], "LÖVR's '" .. name .. "' is a named key")
  end
  expect.equal(translation.FROM_LOVR.a, 30, 'A is not a platform scancode')
  expect.equal(translation.FROM_LOVR.kpenter, 96, 'keypad Enter is distinct from Enter')
  expect.equal(translation.FROM_LOVR.ralt, 100, 'right Alt is distinct from left Alt')
end)

test('polled modifiers include Shift and distinguish right Alt from command Alt', function()
  local held: { [string]: boolean } = { lshift = true, ralt = true }
  local function query(name: string): boolean
    return held[name] == true
  end
  expect.equal(table.concat(translation.held(query), ','), 'mod5,shift', 'AltGr and Shift')
  held.lalt = true
  expect.equal(table.concat(translation.held(query), ','), 'alt,mod5,shift', 'both Alt keys')
end)

test('the host snapshot names the logo modifier and is authoritative except for the side of Alt', function()
  expect.truthy(host({ super = true }).logo, "LÖVR's super is the logo modifier")
  local queried: { string } = {}
  local function held(name: string): boolean
    queried[#queried + 1] = name
    return name == 'ralt'
  end
  local names = translation.fromHost(host { alt = true, shift = true, numLock = true }, held)
  expect.equal(table.concat(names, ','), 'mod5,shift,numLock', 'right Alt remains level three')
  for _, name in queried do
    expect.truthy(name == 'ralt' or name == 'lalt', 'only sided Alt queries remain')
  end
  names = translation.fromHost(host { control = true, super = true, capsLock = true }, function(): boolean
    return true
  end)
  expect.equal(table.concat(names, ','), 'control,logo,capsLock', 'event commands and locks, whatever is polled')
end)

return test
