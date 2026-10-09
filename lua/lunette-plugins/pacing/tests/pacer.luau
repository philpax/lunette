local testing = require '@testing'
local expect = testing.expect

local pacing = require '@lunette-plugins/pacing/pacer'

local test = testing.suite()

-- A short history with round numbers. A case can count the observations manually.
local TUNING = {
  background = 1,
  exempt = 30,
  history = 4,
  busy = 0.5,
  exemptTypes = { none = false, photo = false, video = true, game = true },
}

local function pacer(tuning)
  return pacing.new(tuning or TUNING)
end

-- Feeds `count` observations of the same state to the pacer and returns the
-- last rate.
local function observe(paced, state, count)
  local rate
  for _ = 1, count or 1 do
    rate = paced:observe(state)
  end
  return rate
end

test('a window in view is unthrottled', function()
  local rate = pacer():observe { visible = true, contentType = 'none' }

  expect.equal(rate, nil, 'the rate for a window in view')
end)

test('a quiet window out of view falls to the background rate', function()
  local paced = pacer()

  local rate = observe(paced, { visible = false, contentType = 'none', drew = false }, 4)

  expect.equal(rate, 1, 'the rate for a window nobody is looking at')
end)

test('a window reporting video is exempt even when it commits nothing', function()
  local paced = pacer()

  -- A paused video player commits nothing. The commit record alone would
  -- indicate an idle client; the hint exempts it.
  local rate = observe(paced, { visible = false, contentType = 'video', drew = false }, 4)

  expect.equal(rate, 30, 'the rate for a paused video out of view')
end)

test('a window reporting game is exempt on the same footing', function()
  local paced = pacer()

  local rate = observe(paced, { visible = false, contentType = 'game', drew = false }, 4)

  expect.equal(rate, 30, 'the rate for a game out of view')
end)

test('a busy window is exempt without reporting anything', function()
  local paced = pacer()

  -- The case the hint does not cover. Adoption of `wp_content_type_v1` is
  -- thin, and a client playing video usually reports 'none'.
  local rate = observe(paced, { visible = false, contentType = 'none', drew = true }, 4)

  expect.equal(rate, 30, 'the rate for a client redrawing every frame')
end)

test('a window committing under the busy fraction is not exempt', function()
  local paced = pacer()

  -- One commit in four is a quarter, and the threshold is a half. A terminal
  -- with a blinking cursor commits at about this rate.
  paced:observe { visible = false, contentType = 'none', drew = true }
  local rate = observe(paced, { visible = false, contentType = 'none', drew = false }, 3)

  expect.equal(rate, 1, 'the rate for a client redrawing occasionally')
end)

test('the busy fraction is inclusive at its boundary', function()
  local paced = pacer()

  paced:observe { visible = false, contentType = 'none', drew = true }
  paced:observe { visible = false, contentType = 'none', drew = true }
  paced:observe { visible = false, contentType = 'none', drew = false }
  local rate = paced:observe { visible = false, contentType = 'none', drew = false }

  expect.equal(rate, 30, 'the rate at exactly the busy fraction')
end)

test('a window that stops committing stops being exempt once the history turns over', function()
  local paced = pacer()
  expect.equal(observe(paced, { visible = false, contentType = 'none', drew = true }, 4), 30, 'the rate while busy')

  -- Four quiet observations match the history length, and no busy sample
  -- remains in the ring.
  local rate = observe(paced, { visible = false, contentType = 'none', drew = false }, 4)

  expect.equal(rate, 1, 'the rate after the busy history aged out')
end)

test('a window is judged on the samples it has, not the whole history', function()
  local paced = pacer()

  -- Two observations into a history of four. Counting the empty slots as quiet
  -- would put the commit fraction at a quarter after the first commit and at a
  -- half after the second. A starting video player would run at the background
  -- rate during its first frame.
  local rate = observe(paced, { visible = false, contentType = 'none', drew = true }, 2)

  expect.equal(rate, 30, 'the rate for a window two frames old')
end)

test('a pacer with no observations at all is not busy', function()
  local rate = pacer():observe { visible = false, contentType = 'none' }

  expect.equal(rate, 1, 'the rate for a pacer that has seen nothing')
end)

test('coming back into view returns the window to unthrottled', function()
  local paced = pacer()
  expect.equal(observe(paced, { visible = false, contentType = 'none', drew = false }, 4), 1, 'the rate out of view')

  local rate = paced:observe { visible = true, contentType = 'none', drew = false }

  expect.equal(rate, nil, 'the rate on coming back into view')
end)

test('a history of one still works', function()
  local paced = pacer {
    history = 1,
    busy = 0.5,
    background = 1,
    exempt = 30,
    exemptTypes = { none = false, photo = false, video = false, game = false },
  }

  expect.equal(paced:observe { visible = false, drew = true }, 30, 'the rate after one commit')
  expect.equal(paced:observe { visible = false, drew = false }, 1, 'the rate after one quiet frame')
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
