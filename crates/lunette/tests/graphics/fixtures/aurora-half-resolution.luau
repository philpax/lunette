-- Compares actual production half-resolution curtains with the independent prior-direct composition.
local testing = require '@testing'
local capture = require './support/aurora-half-resolution-capture'

local test = testing.suite()
-- These linear-light budgets precede measurement and cover RGB independently of alpha and nonblank guards.
-- The reference accumulates directly into RGBA8; production accumulates into a half-size RGBA16F stereo target.
local BOUNDS: capture.Bounds = { maximum = 0.15, mean = 0.003, rms = 0.01, alpha = 0.03 }

test(
  'eligible stereo production curtains preserve the direct composition with single-sample and MSAA main canvases',
  function(): ()
    capture.withFixture({}, function(current: capture.Fixture): ()
      for _, samples in { 1, 4 } do
        local scenarios: { capture.Scenario } = {
          { name = 'dense horizon', count = 34 },
          { name = 'silent horizon', silent = true },
          { name = 'eight analytic onsets', count = 8 },
          { name = 'dense partial visibility', count = 34, visibility = 0.35 },
          { name = 'dense upward view', count = 34, angle = 'up' },
          { name = 'dense downward view', count = 34, angle = 'down' },
          { name = 'emissive onset strength', count = 34, strength = 3, visibility = 0.65 },
        }
        for _, scenario in scenarios do
          scenario.samples = samples
          capture.compare(current, scenario, BOUNDS)
        end
      end
    end)
  end
)

test('high palette energy and a larger stereo canvas stay within the original half-resolution budgets', function(): ()
  capture.withFixture({
    palette = {
      low = { 1, 0.85, 0.95 },
      high = { 0.95, 1, 0.9 },
      bass = { 1, 0.5, 0.8 },
      mid = { 0.65, 1, 0.6 },
      treble = { 0.7, 0.6, 1 },
    },
  }, function(current: capture.Fixture): ()
    for _, samples in { 1, 4 } do
      capture.compare(current, {
        name = 'high palette emissive partial visibility',
        count = 34,
        samples = samples,
        visibility = 0.5,
        strength = 2,
      }, BOUNDS)
    end
    capture.compare(current, {
      name = 'high palette 1920x1280 MSAA stereo',
      count = 17,
      width = 1920,
      height = 1280,
      samples = 4,
      visibility = 0.4,
    }, BOUNDS)
  end)
end)

test('production half-resolution fields follow three 90 Hz frames and fresh waves at an unchanged clock', function(): ()
  capture.withFixture({}, function(current: capture.Fixture): ()
    local previous: capture.Pair? = nil
    for step = 0, 2 do
      local scenario: capture.Scenario = {
        name = string.format('90 Hz dense frame %d', step),
        count = 34,
        age = 0.081 + step / 90,
        time = 123 + step / 90,
        visibility = 0.45,
      }
      local pair = capture.compare(current, scenario, BOUNDS)
      if previous then
        capture.tracksChange(previous, pair, scenario.name)
      end
      previous = pair
    end
    local scenario: capture.Scenario = {
      name = 'same Frame repeat',
      count = 17,
      age = 0.081,
      time = 124,
      visibility = 0.45,
      samples = 4,
    }
    local frame = capture.observed(scenario)
    local first = capture.compare(current, scenario, BOUNDS, frame)
    capture.identical(first, capture.compare(current, scenario, BOUNDS, frame), 'same Frame after submission')
    capture.identical(first, capture.compare(current, scenario, BOUNDS), 'fresh Frame with the same clock and waves')
    local changed = capture.compare(current, {
      name = 'same clock changed waves',
      count = 17,
      age = 0.081,
      time = 124,
      shift = 0.11,
      visibility = 0.45,
      samples = 4,
    }, BOUNDS)
    capture.tracksChange(first, changed, 'same clock changed waves')
    capture.identical(first, capture.compare(current, scenario, BOUNDS), 'same-clock waves recover')
  end)
end)

test('miniature-first main recording cannot leave preparation draws reading stale sky or onset fields', function(): ()
  local first: capture.Pair? = nil
  capture.withFixture({}, function(current: capture.Fixture): ()
    local scenario: capture.Scenario = {
      name = 'miniature recorded before scene',
      count = 34,
      time = 200,
      visibility = 0.45,
      samples = 4,
      miniature = 'first',
    }
    local frame = capture.observed(scenario)
    first = capture.compare(current, scenario, BOUNDS, frame)
    local changed = capture.compare(current, {
      name = 'miniature first with fresh same-clock fields',
      count = 34,
      time = 200,
      age = 0.081,
      shift = 0.13,
      visibility = 0.45,
      samples = 4,
      miniature = 'first',
    }, BOUNDS)
    capture.tracksChange(first, changed, 'miniature-first fields refresh at the same clock')
  end)
  capture.withFixture({}, function(current: capture.Fixture): ()
    local last = capture.compare(current, {
      name = 'scene recorded before miniature',
      count = 34,
      time = 200,
      visibility = 0.45,
      samples = 4,
      miniature = 'last',
    }, BOUNDS)
    assert(first, 'miniature-first capture completes')
    capture.identical(first, last, 'off-frustum miniature recording order does not alter scene RGB')
  end)
end)

-- These offscreen copies complement the native OpenVR backend recorder without executing OpenVR.
test(
  'separate 2D overlay copies preserve the eligible stereo backdrop and independent direct composition',
  function(): ()
    capture.withFixture({}, function(current: capture.Fixture): ()
      for _, samples in { 1, 4 } do
        capture.compare(current, {
          name = 'dense partial visibility overlay copies',
          count = 34,
          width = 960,
          height = 640,
          samples = samples,
          visibility = 0.35,
          overlayCopy = true,
        }, BOUNDS)
      end
    end)
  end
)

return test
