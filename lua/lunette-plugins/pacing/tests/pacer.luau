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

local function pacer(options)
  options = options or {}
  return pacing.new { tuning = options.tuning or TUNING, choose = options.choose }
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
  local rate, changed = pacer():observe { visible = true, contentType = 'none' }

  expect.equal(rate, nil, 'the rate for a window in view')
  expect.truthy(changed, 'whether the first choice counts as a change')
end)

test('a quiet window out of view falls to the background rate', function()
  local paced = pacer()

  local rate = observe(paced, { visible = false, contentType = 'none', drew = false }, 4)

  expect.equal(rate, 1, 'the rate for a window nobody is looking at')
end)

test('the same choice twice reports no change', function()
  local paced = pacer()
  paced:observe { visible = false, contentType = 'none' }

  local rate, changed = paced:observe { visible = false, contentType = 'none' }

  expect.equal(rate, 1, 'the rate it settled on')
  expect.falsy(changed, 'whether choosing the same rate again counts as a change')
end)

test('a window reporting video is exempt even when it commits nothing', function()
  local paced = pacer()

  -- A paused video player commits nothing. The commit record alone would
  -- indicate an idle client; the hint exempts it.
  local rate = observe(paced, { visible = false, contentType = 'video', drew = false }, 4)

  expect.equal(rate, 30, 'the rate for a paused video out of view')
  expect.truthy(paced:isExempt 'video', 'whether the hint alone exempts')
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
  expect.truthy(paced:isExempt 'none', 'whether the commit rate alone exempts')
end)

test('a window committing under the busy fraction is not exempt', function()
  local paced = pacer()

  -- One commit in four is a quarter, and the threshold is a half. A terminal
  -- with a blinking cursor commits at about this rate.
  paced:observe { visible = false, contentType = 'none', drew = true }
  local rate = observe(paced, { visible = false, contentType = 'none', drew = false }, 3)

  expect.equal(rate, 1, 'the rate for a client redrawing occasionally')
  expect.falsy(paced:isExempt 'none', 'whether an occasional commit exempts')
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
  observe(paced, { visible = false, contentType = 'none', drew = true }, 4)
  expect.equal(paced:current(), 30, 'the rate while busy')

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
  expect.falsy(pacer():isExempt 'none', 'whether a pacer that has seen nothing is exempt')
end)

test('coming back into view returns the window to unthrottled', function()
  local paced = pacer()
  observe(paced, { visible = false, contentType = 'none', drew = false }, 4)
  expect.equal(paced:current(), 1, 'the rate while out of view')

  local rate, changed = paced:observe { visible = true, contentType = 'none', drew = false }

  expect.equal(rate, nil, 'the rate on coming back into view')
  expect.truthy(changed, 'whether coming back into view is a change')
end)

test('reset forgets the history and the settled rate', function()
  local paced = pacer()
  observe(paced, { visible = false, contentType = 'none', drew = true }, 4)
  expect.truthy(paced:isExempt 'none', 'whether it was exempt before the reset')

  paced:reset()

  expect.equal(paced:current(), nil, 'the rate after a reset')
  expect.falsy(paced:isExempt 'none', 'whether the busy history survived the reset')
end)

test('a history of one still works', function()
  local paced = pacer {
    tuning = {
      history = 1,
      busy = 0.5,
      background = 1,
      exempt = 30,
      exemptTypes = { none = false, photo = false, video = false, game = false },
    },
  }

  expect.equal(paced:observe { visible = false, drew = true }, 30, 'the rate after one commit')
  expect.equal(paced:observe { visible = false, drew = false }, 1, 'the rate after one quiet frame')
end)

test('a history below one is refused', function()
  expect.raises(function()
    pacing.new { tuning = { history = 0 } }
  end, 'at least one sample', 'the message for a history of zero')
end)

test('an observation that says nothing about drawing adds no sample', function()
  local paced = pacer()
  observe(paced, { visible = false, contentType = 'none', drew = true }, 2)

  -- A throttled window's commits describe the throttle, so its caller passes
  -- no `drew`. Recording those frames as quiet would end the exemption.
  local rate = observe(paced, { visible = false, contentType = 'none' }, 8)

  expect.equal(rate, 30, 'the rate after frames the caller could not judge')
end)

test('a rule replaces the default choice and can call it', function()
  local paced = pacer {
    choose = function(this, observation)
      if observation.visible then
        return 60
      end
      return pacing.rule(TUNING)(this, observation)
    end,
  }

  expect.equal(paced:observe { visible = true }, 60, 'the rate the rule gives a window in view')
  expect.equal(paced:observe { visible = false }, 1, 'the rate the default gives a window out of view')
end)

test('a rule that answers something other than a rate is refused', function()
  for _, bad in ipairs { 0, -1, 'fast', 0 / 0, math.huge } do
    expect.raises(function()
      pacer({
        choose = function()
          return bad
        end,
      }):observe { visible = false }
    end, 'rate in hertz', 'a rule answering ' .. tostring(bad))
  end
end)

test('an observation without a visibility is refused', function()
  expect.raises(function()
    pacer():observe { contentType = 'none' }
  end, 'visible', 'the message for an observation that does not say')
end)

test('observing something that is not a table is refused', function()
  expect.raises(function()
    pacer():observe 'visible'
  end, 'observes a table', 'the message for a non-table observation')
end)

return test
