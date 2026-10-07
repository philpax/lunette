local testing = require '@testing'
local config = require '../config'
local expect = testing.expect
local test = testing.suite()

test('menu settings retain wrist defaults and nested haptic defaults', function()
  local settings = config.schema.parse { haptic = { strength = 0.4 } }
  expect.equal(settings.hand, 'left')
  expect.equal(settings.size, 0.115)
  expect.equal(settings.offset, vector.pack(-0.03, -0.01, 0.125))
  expect.equal(settings.haptic.strength, 0.4)
  expect.equal(settings.haptic.duration, 0.05)
  expect.equal(settings.expanded.width, 0.32)
  expect.equal(settings.expanded.height, 0.4)
  expect.equal(settings.expanded.logicalWidth, 320)
  expect.equal(settings.expanded.logicalHeight, 400)
end)

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
