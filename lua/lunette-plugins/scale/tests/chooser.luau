local testing = require '@testing'
local expect = testing.expect

local scale = require '@lunette-plugins/scale/chooser'

local test = testing.suite()

local LADDER = { 1, 2, 4 }

local TUNING = { reference = 1, raise = 0.1, lower = 0.2, nearest = 0.05 }

local function chooser(steps)
  return scale.new(steps or LADDER, TUNING)
end

local function distanceFor(wanted)
  return 1 / wanted
end

test('the first choice picks a step and clamps it to the ladder', function()
  expect.equal(chooser():choose(distanceFor(2.5)), 2, 'the step for an ideal of 2.5')
  expect.equal(chooser():choose(distanceFor(0.25)), 1, 'the step for an ideal below every rung')
  expect.equal(chooser():choose(distanceFor(50)), 4, 'the step for an ideal far above the ladder')
  -- Zero distance occurs when the viewer's head intersects the panel.
  expect.equal(chooser():choose(0), 4, 'the step for a panel at no distance at all')
end)

test('hysteresis holds a step across each margin, and the dead band changes nothing', function()
  local rising = chooser()
  expect.equal(rising:choose(distanceFor(1)), 1, 'the step it settled on')
  expect.equal(rising:choose(distanceFor(2.19)), 1, 'the step just short of the raise threshold')
  expect.equal(rising:choose(distanceFor(2.21)), 2, 'the step just past the raise threshold')

  local falling = chooser()
  expect.equal(falling:choose(distanceFor(2.5)), 2, 'the step it settled on')
  expect.equal(falling:choose(distanceFor(1.9)), 2, 'the step at an ideal below the rung')
  expect.equal(falling:choose(distanceFor(1.61)), 2, 'the step just short of the lower threshold')
  expect.equal(falling:choose(distanceFor(1.59)), 1, 'the step just past the lower threshold')

  local settled = chooser()
  settled:choose(distanceFor(2.5))
  for _, ideal in ipairs { 2.0, 1.98, 2.05, 1.95, 2.1, 1.9 } do
    local chosen, changed = settled:choose(distanceFor(ideal))
    expect.equal(chosen, 2, 'the step at an ideal of ' .. ideal)
    expect.falsy(changed, 'whether the step changed at an ideal of ' .. ideal)
  end
end)

test('a jump of several steps arrives in one call', function()
  local picked = chooser()
  expect.equal(picked:choose(distanceFor(1)), 1, 'the step it settled on')

  -- A limit of one rung per call re-renders at every rung on the way.
  expect.equal(picked:choose(distanceFor(20)), 4, 'the step after a jump to the far end')
  expect.equal(picked:choose(distanceFor(0.1)), 1, 'the step after a jump back')
end)

test('every step is on the ladder, and a walk only closes or only recedes monotonically', function()
  local rungs = {}
  for _, rung in ipairs(LADDER) do
    rungs[rung] = true
  end

  -- The walk covers the range and returns at a finer grain than either margin,
  -- so the sweep passes through every threshold in both directions.
  local closing = chooser()
  local previous = closing:choose(10)
  for tenths = 100, 1, -1 do
    local chosen = closing:choose(tenths / 10)
    expect.truthy(rungs[chosen], 'the scale ' .. chosen .. ' is a rung of the ladder')
    -- Hysteresis widens the band a rung holds and can delay a rise; a delayed
    -- rise must not appear as a fall.
    expect.truthy(chosen >= previous, 'the scale fell from ' .. previous .. ' to ' .. chosen .. ' while closing')
    previous = chosen
  end

  local receding = chooser()
  previous = receding:choose(0.1)
  for tenths = 1, 100 do
    local chosen = receding:choose(tenths / 10)
    expect.truthy(rungs[chosen], 'the scale ' .. chosen .. ' is a rung of the ladder')
    expect.truthy(chosen <= previous, 'the scale rose from ' .. previous .. ' to ' .. chosen .. ' while receding')
    previous = chosen
  end
end)

return test
