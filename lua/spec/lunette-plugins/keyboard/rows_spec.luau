-- Covers lua/lunette-plugins/keyboard/rows.luau.
--
-- The module is a data table. The checker types each key's name, so a
-- misspelt key does not reach here; the tests verify the shape of the rows
-- and that the keys a keyboard cannot do without are drawn.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local keys = require '@lunette-contracts/keys'
local rows = require '@lunette-plugins/keyboard/rows'

local spec = suite.new 'lunette-plugins.keyboard.rows'

spec('every key has a keycode and appears once', function()
  local seen = {}
  local count = 0
  for rowIndex, row in ipairs(rows) do
    for entryIndex, entry in ipairs(row) do
      local where = 'row ' .. rowIndex .. ', key ' .. entryIndex
      expect.equal(type(entry.code), 'number', where .. ': the keycode')
      expect.falsy(seen[entry.code], where .. ': keycode ' .. tostring(entry.code) .. ' appears twice')
      seen[entry.code] = true
      count += 1
    end
  end
  expect.truthy(count > 0, 'the keys in the rows')
end)

spec('every width is a positive number of key units', function()
  for rowIndex, row in ipairs(rows) do
    for entryIndex, entry in ipairs(row) do
      if entry.width ~= nil then
        expect.truthy(
          type(entry.width) == 'number' and entry.width > 0,
          'row ' .. rowIndex .. ', key ' .. entryIndex .. ': the width'
        )
      end
    end
  end
end)

spec('the keys a keyboard cannot do without are drawn', function()
  local present = {}
  for _, row in ipairs(rows) do
    for _, entry in ipairs(row) do
      present[entry.code] = true
    end
  end

  local codes = keys.CODES
  for _, name in ipairs { 'leftShift', 'capsLock', 'backspace', 'enter', 'space' } do
    expect.truthy(present[codes[name]], name .. ' is drawn on the keyboard')
  end
end)

return spec
