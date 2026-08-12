-- Covers lua/mullion/scale.lua.
--
-- The whole module is pure, so every case here drives a chooser with numbers
-- and reads the scale back. What is worth asserting is the hysteresis: that a
-- distance approaching a boundary changes nothing until it is crossed, that
-- crossing back needs more than crossing forward did, and that a panel at
-- either end of the ladder clamps rather than running off it.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local lunette = require '@lunette'
local scale = require '@mullion/scale'

local spec = suite.new 'mullion.scale'

-- A ladder with round rungs, so a case can name a distance and a rung and the
-- arithmetic between them is readable. The real ladder is exercised separately.
local LADDER = { 1, 2, 4 }

-- Tuning with round margins, for the reason the ladder has round rungs. The
-- reference is one metre, so a distance in metres is the reciprocal of the
-- ideal scale.
local TUNING = { reference = 1, raise = 0.1, lower = 0.2, nearest = 0.05 }

local function chooser(options)
  options = options or {}
  return scale.newChooser {
    steps = options.steps or LADDER,
    tuning = options.tuning or TUNING,
  }
end

-- The distance at which the ideal scale is `wanted`, given a reference of one.
local function distanceFor(wanted)
  return 1 / wanted
end

spec('the first distance picks a step outright', function()
  -- No previous step means no hysteresis to hold it back. An ideal of 2.5 takes
  -- the largest rung no greater than it.
  local chosen = chooser():choose(distanceFor(2.5))

  expect.equal(chosen, 2, 'the step for an ideal of 2.5')
end)

spec('the first distance below the ladder clamps to its bottom', function()
  local chosen = chooser():choose(distanceFor(0.25))

  expect.equal(chosen, 1, 'the step for an ideal below every rung')
end)

spec('a distance beyond the top of the ladder clamps to it', function()
  local picked = chooser()

  expect.equal(picked:choose(distanceFor(50)), 4, 'the step for an ideal far above the ladder')
  -- Walking further in still clamps rather than running off the end.
  expect.equal(picked:choose(distanceFor(500)), 4, 'the step after walking closer still')
end)

spec('a distance of zero takes the top rather than raising', function()
  -- A user who walks their head through a panel is not a caller mistake.
  local chosen = chooser():choose(0)

  expect.equal(chosen, 4, 'the step for a panel at no distance at all')
end)

spec('approaching a rung does not change the step until the margin is passed', function()
  local picked = chooser()
  picked:choose(distanceFor(1))
  expect.equal(picked:current(), 1, 'the step it settled on')

  -- The rung above is 2, and the raise margin is a tenth, so 2.19 is not enough.
  local held, changed = picked:choose(distanceFor(2.19))
  expect.equal(held, 1, 'the step just short of the raise threshold')
  expect.falsy(changed, 'whether the step changed')

  local raised, moved = picked:choose(distanceFor(2.21))
  expect.equal(raised, 2, 'the step just past the raise threshold')
  expect.truthy(moved, 'whether the step changed')
end)

spec('crossing back needs the lower threshold, not the upper one', function()
  local picked = chooser()
  picked:choose(distanceFor(2.5))
  expect.equal(picked:current(), 2, 'the step it settled on')

  -- The ideal that would not have reached this rung from below — anything under
  -- 2 — still does not give it back. The lower threshold is a fifth below the
  -- rung, so it takes an ideal under 1.6.
  expect.equal(picked:choose(distanceFor(1.9)), 2, 'the step at an ideal below the rung')
  expect.equal(picked:choose(distanceFor(1.61)), 2, 'the step just short of the lower threshold')
  expect.equal(picked:choose(distanceFor(1.59)), 1, 'the step just past the lower threshold')
end)

spec('the dead band means an ideal oscillating around a rung changes nothing', function()
  local picked = chooser()
  picked:choose(distanceFor(2.5))

  -- The user breathing, in numbers: the ideal wanders either side of the rung
  -- and neither threshold is reached, so the client is never told anything.
  for _, ideal in ipairs { 2.0, 1.98, 2.05, 1.95, 2.1, 1.9 } do
    local chosen, changed = picked:choose(distanceFor(ideal))
    expect.equal(chosen, 2, 'the step at an ideal of ' .. ideal)
    expect.falsy(changed, 'whether the step changed at an ideal of ' .. ideal)
  end
end)

spec('a jump of several steps arrives in one call', function()
  local picked = chooser()
  picked:choose(distanceFor(1))
  expect.equal(picked:current(), 1, 'the step it settled on')

  -- One rung a call would make the client re-render at every rung on the way.
  expect.equal(picked:choose(distanceFor(20)), 4, 'the step after a jump to the far end')
  expect.equal(picked:choose(distanceFor(0.1)), 1, 'the step after a jump back')
end)

spec('resetting drops the hysteresis so the next choice is made outright', function()
  local picked = chooser()
  picked:choose(distanceFor(2.5))
  expect.equal(picked:current(), 2, 'the step it settled on')

  picked:reset()
  expect.equal(picked:current(), nil, 'the step after a reset')
  -- An ideal of 1.9 would have kept the rung of 2 through hysteresis; without a
  -- previous step it takes the largest rung no greater than it.
  expect.equal(picked:choose(distanceFor(1.9)), 1, 'the step chosen after a reset')
end)

spec('every scale a chooser emits is on the ladder it was given', function()
  local picked = chooser()
  local rungs = {}
  for _, rung in ipairs(LADDER) do
    rungs[rung] = true
  end

  -- A walk in and out again, at a finer grain than either margin, so the sweep
  -- passes through every threshold in both directions.
  for tenths = 1, 100 do
    local chosen = picked:choose(tenths / 10)
    expect.truthy(rungs[chosen], 'the scale ' .. chosen .. ' is a rung of the ladder')
  end
  for tenths = 100, 1, -1 do
    local chosen = picked:choose(tenths / 10)
    expect.truthy(rungs[chosen], 'the scale ' .. chosen .. ' is a rung of the ladder')
  end
end)

spec('a walk that only closes never lowers the step', function()
  -- Monotone in, monotone up. Hysteresis widens the band a rung holds, so it can
  -- delay a rise; a rise it delayed must not come out as a fall.
  local picked = chooser()
  local previous = picked:choose(10)

  for tenths = 100, 1, -1 do
    local chosen = picked:choose(tenths / 10)
    expect.truthy(chosen >= previous, 'the scale fell from ' .. previous .. ' to ' .. chosen .. ' while closing')
    previous = chosen
  end
end)

spec('a walk that only recedes never raises the step', function()
  local picked = chooser()
  local previous = picked:choose(0.1)

  for tenths = 1, 100 do
    local chosen = picked:choose(tenths / 10)
    expect.truthy(chosen <= previous, 'the scale rose from ' .. previous .. ' to ' .. chosen .. ' while receding')
    previous = chosen
  end
end)

-- The real ladder, which is the one the layer pool keys on.

spec('the default ladder is the one the native layer publishes', function()
  local published = lunette.scaleSteps()

  expect.equal(#scale.STEPS, #published, 'the number of rungs')
  for index = 1, #published do
    expect.equal(scale.STEPS[index], published[index], 'rung ' .. index)
  end
end)

spec('a chooser given no ladder uses the default one', function()
  local picked = scale.newChooser()

  -- The bottom of the published ladder is 1, and a panel far away asks for less
  -- than that, so it clamps there.
  expect.equal(picked:choose(1000), scale.STEPS[1], 'the step for a very distant panel')
  expect.equal(picked:choose(0.01), scale.STEPS[#scale.STEPS], 'the step for a very near one')
end)

spec('a ladder that is not one is refused', function()
  expect.raises(function()
    scale.newChooser { steps = {} }
  end, 'ladder', 'an empty ladder')
  expect.raises(function()
    scale.newChooser { steps = 3 }
  end, 'ladder', 'a ladder that is not a table')
end)

spec('a distance that is not a number is refused', function()
  for _, bad in ipairs { 'near', {}, true } do
    expect.raises(function()
      chooser():choose(bad)
    end, 'distance', 'a distance of ' .. type(bad))
  end
  expect.raises(function()
    chooser():choose(0 / 0)
  end, 'distance', 'a distance that is not a number')
end)

return spec
