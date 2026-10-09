local testing = require '@testing'
local expect = testing.expect

local lunette = require '@lunette'
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

test('the first distance picks a step outright', function()
  local chosen = chooser():choose(distanceFor(2.5))

  expect.equal(chosen, 2, 'the step for an ideal of 2.5')
end)

test('the first distance below the ladder clamps to its bottom', function()
  local chosen = chooser():choose(distanceFor(0.25))

  expect.equal(chosen, 1, 'the step for an ideal below every rung')
end)

test('a distance beyond the top of the ladder clamps to it', function()
  local picked = chooser()

  expect.equal(picked:choose(distanceFor(50)), 4, 'the step for an ideal far above the ladder')
  expect.equal(picked:choose(distanceFor(500)), 4, 'the step after walking closer still')
end)

test('a distance of zero takes the top rather than raising', function()
  -- Zero distance occurs when the viewer's head intersects the panel.
  local chosen = chooser():choose(0)

  expect.equal(chosen, 4, 'the step for a panel at no distance at all')
end)

test('approaching a rung does not change the step until the margin is passed', function()
  local picked = chooser()
  expect.equal(picked:choose(distanceFor(1)), 1, 'the step it settled on')
  expect.equal(picked:choose(distanceFor(2.19)), 1, 'the step just short of the raise threshold')
  expect.equal(picked:choose(distanceFor(2.21)), 2, 'the step just past the raise threshold')
end)

test('crossing back needs the lower threshold, not the upper one', function()
  local picked = chooser()
  expect.equal(picked:choose(distanceFor(2.5)), 2, 'the step it settled on')
  expect.equal(picked:choose(distanceFor(1.9)), 2, 'the step at an ideal below the rung')
  expect.equal(picked:choose(distanceFor(1.61)), 2, 'the step just short of the lower threshold')
  expect.equal(picked:choose(distanceFor(1.59)), 1, 'the step just past the lower threshold')
end)

test('the dead band means an ideal oscillating around a rung changes nothing', function()
  local picked = chooser()
  picked:choose(distanceFor(2.5))

  for _, ideal in ipairs { 2.0, 1.98, 2.05, 1.95, 2.1, 1.9 } do
    local chosen, changed = picked:choose(distanceFor(ideal))
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

test('every scale a chooser emits is on the ladder it was given', function()
  local picked = chooser()
  local rungs = {}
  for _, rung in ipairs(LADDER) do
    rungs[rung] = true
  end

  -- The walk covers the range and returns at a finer grain than either margin,
  -- so the sweep passes through every threshold in both directions.
  for tenths = 1, 100 do
    local chosen = picked:choose(tenths / 10)
    expect.truthy(rungs[chosen], 'the scale ' .. chosen .. ' is a rung of the ladder')
  end
  for tenths = 100, 1, -1 do
    local chosen = picked:choose(tenths / 10)
    expect.truthy(rungs[chosen], 'the scale ' .. chosen .. ' is a rung of the ladder')
  end
end)

test('a walk that only closes never lowers the step', function()
  -- The walk is monotone in distance, so the step is monotone up. Hysteresis
  -- widens the band a rung holds and can delay a rise; a delayed rise must not
  -- appear as a fall.
  local picked = chooser()
  local previous = picked:choose(10)

  for tenths = 100, 1, -1 do
    local chosen = picked:choose(tenths / 10)
    expect.truthy(chosen >= previous, 'the scale fell from ' .. previous .. ' to ' .. chosen .. ' while closing')
    previous = chosen
  end
end)

test('a walk that only recedes never raises the step', function()
  local picked = chooser()
  local previous = picked:choose(0.1)

  for tenths = 1, 100 do
    local chosen = picked:choose(tenths / 10)
    expect.truthy(chosen <= previous, 'the scale rose from ' .. previous .. ' to ' .. chosen .. ' while receding')
    previous = chosen
  end
end)

test('a chooser on the published ladder clamps to its ends', function()
  local published = lunette.scaleSteps()
  local picked = chooser(published)

  -- The bottom of the published ladder is 1. A far panel produces an ideal
  -- below that, and the step clamps to it.
  expect.equal(picked:choose(1000), published[1], 'the step for a very distant panel')
  expect.equal(picked:choose(0.01), published[#published], 'the step for a very near one')
end)

return test
