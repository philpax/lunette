local testing = require '@testing'
local motion = require '../private/motion'
local expect = testing.expect
local test = testing.suite()

local function run(channel: motion.Channel, seconds: number, duration: number, dt: number?): ()
  local step = dt or 1 / 90
  for _ = 1, math.ceil(seconds / step) do
    motion.step(channel, step, duration)
  end
end

test('a channel settles within its duration without overshooting', function()
  local channel = motion.channel(0)
  channel.target = 1
  local highest = 0
  for _ = 1, 30 do
    motion.step(channel, 1 / 90, 0.12)
    highest = math.max(highest, channel.value)
  end
  expect.truthy(highest <= 1 + 1e-9, 'no overshoot')
  run(channel, 0.12, 0.12)
  expect.near(channel.value, 1, 0.02, 'settled within the duration')
end)

test('a new target keeps the velocity, so the motion turns around smoothly', function()
  local channel = motion.channel(0)
  channel.target = 1
  run(channel, 0.03, 0.12)
  local before = channel.value
  channel.target = 0
  motion.step(channel, 1 / 90, 0.12)
  expect.truthy(channel.value > before, 'the value keeps rising for a moment after the target turns')
  run(channel, 0.5, 0.12)
  expect.near(channel.value, 0, 1e-3)
end)

test('a long frame cannot overshoot, and a zero duration snaps', function()
  local channel = motion.channel(0)
  channel.target = 1
  motion.step(channel, 2, 0.12)
  expect.truthy(channel.value <= 1 and channel.value > 0.99)
  local snapped = motion.channel(0)
  snapped.target = 5
  motion.step(snapped, 1 / 90, 0)
  expect.equal(snapped.value, 5)
end)

test('a panel takes input only while its owner opacity is visible and not fading out', function()
  local panel: any = { visible = true, opacity = motion.channel(1) }
  expect.truthy(motion.shown(panel), 'opaque')
  panel.opacity.target = 0
  expect.falsy(motion.shown(panel), 'fading out')
  panel.opacity = { value = 0.05, target = 1, velocity = 0 }
  expect.falsy(motion.shown(panel), 'nearly transparent while fading in')
  panel.opacity.value = 0.5
  expect.truthy(motion.shown(panel), 'half faded in')
  panel.visible = false
  expect.falsy(motion.shown(panel), 'hidden')
end)

return test
