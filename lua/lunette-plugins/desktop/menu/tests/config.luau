local testing = require '@testing'
local config = require '../config'
local expect = testing.expect
local test = testing.suite()

test('menu geometry and haptic settings reject invalid values', function()
  for _, value in
    {
      { hand = 'middle' },
      { size = 0 },
      { size = math.huge },
      { offset = { 1, 2, 3 } },
      { haptic = { strength = -0.1 } },
      { haptic = { strength = 1.1 } },
      { haptic = { duration = -1 } },
      { expanded = { width = 0 } },
      { expanded = { logicalWidth = 1 } },
      { expanded = { logicalHeight = 1 } },
      { expanded = { rowHeight = 0 } },
    }
  do
    expect.raises(function()
      config.schema.parse(value)
    end)
  end
end)

return test
