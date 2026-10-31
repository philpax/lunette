local testing = require '@testing'
local visibility = require '../private/visibility'
local expect = testing.expect
local test = testing.suite()

local function frame(overrides: { [string]: any }): visibility.Frame
  local base = { mode = 'engaged', overlaid = true, engaged = false, dt = 0.01, fadeOut = 0.1 }
  for key, value in overrides do
    base[key] = value
  end
  return base :: any
end

test('a beam shows fully without another scene, in always mode, or while engaged', function()
  expect.equal(visibility.step(0, frame { overlaid = false }), 1)
  expect.equal(visibility.step(0, frame { mode = 'always' }), 1)
  expect.equal(visibility.step(0, frame { engaged = true }), 1)
end)

test('an idle beam over another scene fades out over its fade time and stays out', function()
  local current = 1
  for step = 1, 10 do
    local next = visibility.step(current, frame {})
    expect.truthy(next < current, `step {step} lowers the opacity`)
    current = next
  end
  expect.near(current, 0, 1e-9, 'gone after the fade time')
  expect.equal(visibility.step(current, frame {}), 0, 'stays gone')
end)

test('an opacity stays within 0 and 1 for any frame length', function()
  for _, dt in { 0, 1e-6, 0.016, 0.5, 100 } do
    for _, current in { 0, 0.3, 1 } do
      local next = visibility.step(current, frame { dt = dt })
      expect.truthy(next >= 0 and next <= 1, `dt {dt} from {current}`)
    end
  end
end)

test('without timing or a fade time, an idle beam hides at once', function()
  local untimed: visibility.Frame = { mode = 'engaged', overlaid = true, engaged = false, fadeOut = 0.1 }
  expect.equal(visibility.step(1, untimed), 0)
  expect.equal(visibility.step(1, frame { fadeOut = 0 }), 0)
end)

return test
