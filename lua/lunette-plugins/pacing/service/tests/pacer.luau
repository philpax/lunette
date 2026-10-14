local testing = require '@testing'
local expect = testing.expect

local pacing = require '../private/pacer'

local test = testing.suite()

-- A short history with round numbers, so a case can count its observations by hand.
local TUNING = {
  background = 1,
  exempt = 30,
  history = 4,
  busy = 0.5,
  exemptTypes = { none = false, photo = false, video = true, game = true },
}

local ONE_FRAME = {
  background = 1,
  exempt = 30,
  history = 1,
  busy = 0.5,
  exemptTypes = { none = false, photo = false, video = false, game = false },
}

local function pacer(tuning: pacing.Tuning?): pacing.Pacer
  return pacing.new(tuning or TUNING)
end

-- Feeds `count` observations of the same state to the pacer and returns the
-- last rate.
local function observe(paced: pacing.Pacer, state: pacing.Observation, count: number?): number?
  local rate: number?
  for _ = 1, count or 1 do
    rate = paced:observe(state)
  end
  return rate
end

-- Feeds one observation per character: 'd' draws, 'q' is quiet, and 's' says
-- nothing about drawing. Returns the last rate.
local DRAWING: { [string]: pacing.Observation } = {
  d = { visible = false, contentType = 'none', drew = true },
  q = { visible = false, contentType = 'none', drew = false },
  s = { visible = false, contentType = 'none' },
}

local function observeFrames(paced: pacing.Pacer, frames: string): number?
  local rate: number?
  for index = 1, #frames do
    rate = paced:observe(DRAWING[frames:sub(index, index)])
  end
  return rate
end

test('visibility and the content hint choose the rate', function()
  local quiet = { visible = false, contentType = 'none', drew = false }
  for _, case in ipairs {
    { name = 'a window in view', state = { visible = true, contentType = 'none' }, count = 1, rate = nil },
    { name = 'a quiet window out of view', state = quiet, count = 4, rate = 1 },
    -- A paused video player commits nothing, so the commit record alone would
    -- read it as idle. The hint exempts it.
    {
      name = 'a paused video out of view',
      state = { visible = false, contentType = 'video', drew = false },
      count = 4,
      rate = 30,
    },
    {
      name = 'a game out of view',
      state = { visible = false, contentType = 'game', drew = false },
      count = 4,
      rate = 30,
    },
  } do
    expect.equal(observe(pacer(), case.state, case.count), case.rate, case.name)
  end

  local paced = pacer()
  expect.equal(observe(paced, quiet, 4), 1, 'the rate out of view')
  expect.equal(paced:observe { visible = true, contentType = 'none', drew = false }, nil, 'the rate back in view')
end)

test('the commit history makes a window busy', function()
  -- A commit in four is a quarter, under the half threshold. A terminal with a
  -- blinking cursor commits at about this rate.
  for _, case in ipairs {
    { name = 'a busy window', frames = 'dddd', rate = 30 },
    { name = 'a window committing under the busy fraction', frames = 'dqqq', rate = 1 },
    { name = 'the busy fraction is inclusive at its boundary', frames = 'ddqq', rate = 30 },
    -- Four quiet observations match the history length, so no busy sample
    -- remains in the ring.
    { name = 'a window that stops committing, once the history turns over', frames = 'ddddqqqq', rate = 1 },
    -- Two observations into a history of four. Counting the empty slots as
    -- quiet would put the commit fraction at a quarter after the first commit
    -- and at a half after the second.
    { name = 'a window judged on the samples it has', frames = 'dd', rate = 30 },
    { name = 'a pacer with no observations at all', frames = 's', rate = 1 },
  } do
    expect.equal(observeFrames(pacer(), case.frames), case.rate, case.name)
  end

  expect.equal(observeFrames(pacing.new(ONE_FRAME), 'd'), 30, 'a history of one, after a commit')
  expect.equal(observeFrames(pacing.new(ONE_FRAME), 'dq'), 1, 'a history of one, after a quiet frame')
end)

test('an observation that says nothing about drawing adds no sample', function()
  local paced = pacer()
  observe(paced, { visible = false, contentType = 'none', drew = true }, 2)

  -- A throttled window's commits describe the throttle, so its caller passes
  -- no `drew`. Recording those frames as quiet would end the exemption.
  local rate = observe(paced, { visible = false, contentType = 'none' }, 8)

  expect.equal(rate, 30, 'the rate after frames the caller could not judge')
end)

return test
