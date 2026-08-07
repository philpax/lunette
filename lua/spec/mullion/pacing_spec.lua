-- Covers lua/mullion/pacing.lua.
--
-- The whole module is pure, so every case here drives a pacer with observations
-- and reads the rate back. What is worth asserting is the exemption: that the
-- hint alone exempts a paused video that commits nothing, that a busy client
-- exempts itself without setting a hint at all, and that a window nobody is
-- looking at and nothing is happening in falls to the floor.

local expect = require 'spec.expect'
local suite = require 'spec.suite'

local pacing = require 'mullion.pacing'

local spec = suite.new 'mullion.pacing'

-- A short history with round numbers, so a case can count observations by hand.
local TUNING = {
  foreground = false,
  background = 1,
  exempt = 30,
  history = 4,
  busy = 0.5,
  exemptTypes = { video = true, game = true },
}

local function pacer(options)
  options = options or {}
  return pacing.newPacer { tuning = options.tuning or TUNING }
end

-- Drives `count` observations of the same state and answers the last rate.
local function observe(paced, state, count)
  local rate
  for _ = 1, count or 1 do
    rate = paced:observe(state)
  end
  return rate
end

spec('a window in view is unthrottled', function()
  local rate, changed = pacer():observe { visible = true, contentType = 'none' }

  expect.equal(rate, nil, 'the rate for a window in view')
  expect.truthy(changed, 'whether the first choice counts as a change')
end)

spec('a quiet window out of view falls to the background rate', function()
  local paced = pacer()

  local rate = observe(paced, { visible = false, contentType = 'none', drew = false }, 4)

  expect.equal(rate, 1, 'the rate for a window nobody is looking at')
end)

spec('the same choice twice reports no change', function()
  local paced = pacer()
  paced:observe { visible = false, contentType = 'none' }

  local rate, changed = paced:observe { visible = false, contentType = 'none' }

  expect.equal(rate, 1, 'the rate it settled on')
  expect.falsy(changed, 'whether choosing the same rate again counts as a change')
end)

spec('a window reporting video is exempt even when it commits nothing', function()
  local paced = pacer()

  -- A paused video player. Nothing commits, so the commit rate says idle; the
  -- hint is the only thing that knows better.
  local rate = observe(paced, { visible = false, contentType = 'video', drew = false }, 4)

  expect.equal(rate, 30, 'the rate for a paused video out of view')
  expect.truthy(paced:isExempt 'video', 'whether the hint alone exempts')
end)

spec('a window reporting game is exempt on the same footing', function()
  local paced = pacer()

  local rate = observe(paced, { visible = false, contentType = 'game', drew = false }, 4)

  expect.equal(rate, 30, 'the rate for a game out of view')
end)

spec('a busy window is exempt without reporting anything', function()
  local paced = pacer()

  -- The case the hint misses: adoption of `wp_content_type_v1` is thin, so a
  -- client actually playing video usually reports 'none'.
  local rate = observe(paced, { visible = false, contentType = 'none', drew = true }, 4)

  expect.equal(rate, 30, 'the rate for a client redrawing every frame')
  expect.truthy(paced:isExempt 'none', 'whether the commit rate alone exempts')
end)

spec('a window committing under the busy fraction is not exempt', function()
  local paced = pacer()

  -- One commit in four is a quarter, and the threshold is a half. A terminal
  -- with a blinking cursor lives here.
  paced:observe { visible = false, contentType = 'none', drew = true }
  local rate = observe(paced, { visible = false, contentType = 'none', drew = false }, 3)

  expect.equal(rate, 1, 'the rate for a client redrawing occasionally')
  expect.falsy(paced:isExempt 'none', 'whether an occasional commit exempts')
end)

spec('the busy fraction is inclusive at its boundary', function()
  local paced = pacer()

  paced:observe { visible = false, contentType = 'none', drew = true }
  paced:observe { visible = false, contentType = 'none', drew = true }
  paced:observe { visible = false, contentType = 'none', drew = false }
  local rate = paced:observe { visible = false, contentType = 'none', drew = false }

  expect.equal(rate, 30, 'the rate at exactly the busy fraction')
end)

spec('a window that stops committing stops being exempt once the history turns over', function()
  local paced = pacer()
  observe(paced, { visible = false, contentType = 'none', drew = true }, 4)
  expect.equal(paced:current(), 30, 'the rate while busy')

  -- Four quiet observations is exactly the history, so nothing of the busy
  -- stretch is left in the ring.
  local rate = observe(paced, { visible = false, contentType = 'none', drew = false }, 4)

  expect.equal(rate, 1, 'the rate after the busy history aged out')
end)

spec('a window is judged on the samples it has, not the whole history', function()
  local paced = pacer()

  -- Two observations into a history of four. Counting the empty slots as quiet
  -- would put this at a half of nothing and hold the window out of exemption
  -- for its first frames, which is exactly when a video player is starting.
  local rate = observe(paced, { visible = false, contentType = 'none', drew = true }, 2)

  expect.equal(rate, 30, 'the rate for a window two frames old')
end)

spec('a pacer with no observations at all is not busy', function()
  expect.falsy(pacer():isExempt 'none', 'whether a pacer that has seen nothing is exempt')
end)

spec('coming back into view returns the window to unthrottled', function()
  local paced = pacer()
  observe(paced, { visible = false, contentType = 'none', drew = false }, 4)
  expect.equal(paced:current(), 1, 'the rate while out of view')

  local rate, changed = paced:observe { visible = true, contentType = 'none', drew = false }

  expect.equal(rate, nil, 'the rate on coming back into view')
  expect.truthy(changed, 'whether coming back into view is a change')
end)

spec('reset forgets the history and the settled rate', function()
  local paced = pacer()
  observe(paced, { visible = false, contentType = 'none', drew = true }, 4)
  expect.truthy(paced:isExempt 'none', 'whether it was exempt before the reset')

  paced:reset()

  expect.equal(paced:current(), nil, 'the rate after a reset')
  expect.falsy(paced:isExempt 'none', 'whether the busy history survived the reset')
end)

spec('a history of one still works', function()
  local paced = pacer { tuning = { history = 1, busy = 0.5, foreground = false, background = 1, exempt = 30, exemptTypes = {} } }

  expect.equal(paced:observe { visible = false, drew = true }, 30, 'the rate after one commit')
  expect.equal(paced:observe { visible = false, drew = false }, 1, 'the rate after one quiet frame')
end)

spec('a history below one is refused', function()
  expect.raises(function()
    pacing.newPacer { tuning = { history = 0 } }
  end, 'history of at least one sample', 'the message for a history of zero')
end)

spec('observing something that is not a table is refused', function()
  expect.raises(function()
    pacer():observe 'visible'
  end, 'observes a table', 'the message for a non-table observation')
end)

return spec
