-- Covers lua/mullion/keycodes.lua.
--
-- The module is data, so what is worth checking is that the data agrees with
-- itself: a modifier keycode that names a modifier `sink:modifiers` does not
-- take, or a key that appears twice in the matrix, is the kind of mistake a
-- table this shape invites and that nothing else would notice until a client
-- refused a modifier set at runtime.

local expect = require 'spec.expect'
local suite = require 'spec.suite'

local keycodes = require 'mullion.keycodes'

local spec = suite.new 'mullion.keycodes'

-- Whether `name` is one of the modifier names.
local function isModifierName(name)
  for _, known in ipairs(keycodes.MODIFIER_ORDER) do
    if known == name then
      return true
    end
  end
  return false
end

spec('every key in the matrix has a keycode and appears once', function()
  local seen = {}
  local keys = 0
  for rowIndex, row in ipairs(keycodes.ROWS) do
    for entryIndex, entry in ipairs(row) do
      local where = 'row ' .. rowIndex .. ', key ' .. entryIndex
      expect.equal(type(entry.code), 'number', where .. ': the keycode')
      expect.falsy(seen[entry.code], where .. ': keycode ' .. entry.code .. ' appears twice')
      seen[entry.code] = true
      keys = keys + 1
    end
  end
  expect.truthy(keys > 0, 'the keys in the matrix')
end)

spec('every width in the matrix is a positive number of key units', function()
  for rowIndex, row in ipairs(keycodes.ROWS) do
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

spec('every modifier keycode names a modifier the native surface takes', function()
  -- The names are passed to `sink:modifiers` unchanged, and it raises on one it
  -- does not know. A typo here would be a runtime error in the user's face.
  for code, name in pairs(keycodes.MODIFIERS) do
    expect.truthy(isModifierName(name), 'keycode ' .. code .. " names '" .. name .. "'")
  end
end)

spec('every lock is a modifier name', function()
  for name in pairs(keycodes.LOCKS) do
    expect.truthy(isModifierName(name), "the lock '" .. name .. "'")
  end
end)

spec('the named keycodes are in the matrix', function()
  local named = {
    SHIFT = keycodes.SHIFT,
    CAPS_LOCK = keycodes.CAPS_LOCK,
    BACKSPACE = keycodes.BACKSPACE,
    ENTER = keycodes.ENTER,
    SPACE = keycodes.SPACE,
  }

  local present = {}
  for _, row in ipairs(keycodes.ROWS) do
    for _, entry in ipairs(row) do
      present[entry.code] = true
    end
  end

  for name, code in pairs(named) do
    expect.truthy(present[code], name .. ' is drawn on the keyboard')
  end
end)

spec('the two modifier keycodes that come in pairs name the same modifier', function()
  -- Left and right shift are different keycodes and the same modifier. A
  -- keyboard whose right shift latched something else would be a keyboard on
  -- which half the capital letters came out lowercase.
  expect.equal(keycodes.MODIFIERS[42], 'shift', 'the left shift')
  expect.equal(keycodes.MODIFIERS[54], 'shift', 'the right shift')
  expect.equal(keycodes.MODIFIERS[29], 'control', 'the left control')
  expect.equal(keycodes.MODIFIERS[97], 'control', 'the right control')
end)

return spec
