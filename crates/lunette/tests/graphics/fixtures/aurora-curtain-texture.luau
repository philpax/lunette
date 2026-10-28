-- Compares the maintained renderer's shared onset textures with independent frozen analytic curtain shaders.
local testing = require '@testing'
local config = require '@lunette-plugins/environment/backdrop/config'
local model = require '@lunette-plugins/environment/backdrop/private/rendering/model'
local capture = require './support/aurora-curtain-capture'
local pixels = require './support/pixels'

local test = testing.suite()
-- Linear RGB bounds cover isolated interpolation errors and whole-image error independently. Curtain alpha is
-- approximate too; opaque sky and analytic-only branches retain their separate, stricter bounds.
local MAX_ERROR, MEAN_ERROR, RMS_ERROR = 0.06, 0.0004, 0.002
local ALPHA_MAX, ALPHA_MEAN = 0.01, 1e-4
local ANALYTIC_ERROR, SKY_ALPHA_ERROR = 1e-4, 1e-6
local DIAGNOSTICS = { 'direction', 'coordinates', 'cells', 'density', 'field' }

type Scenario = capture.Scenario
type Fixture = capture.Fixture
type Pair = capture.Pair

local function compare(current: Fixture, scenario: Scenario, supplied: model.Frame?): Pair
  current.view = scenario.view or 0
  local frame = supplied or capture.observed(scenario)
  local actual = capture.images(current, scenario, frame, true)
  local expected = capture.images(current, scenario, frame, false)
  local analytic = #frame.waves <= 8 or frame.brightness == 0 or (current.view > 0 and not scenario.shared)
  local skyOnly = scenario.angle == 'down' or (current.view > 0 and not scenario.shared) or frame.brightness == 0
  for layer, image in actual do
    local error = capture.metrics(image, expected[layer])
    local detail = string.format(
      '%s eye=%d: max %.9g mean %.9g rms %.9g alphaMax %.9g alphaMean %.9g',
      scenario.name,
      layer - 1,
      error.maximum,
      error.mean,
      error.rms,
      error.alpha,
      error.alphaMean
    )
    local partial = current.view == 0
      and (scenario.miniature or scenario.shared or (frame.visibility > 0 and frame.visibility < 1))
    print('aurora curtain texture ' .. detail .. (if partial then ' alpha=partial-coverage' else ' alpha=opaque-sky'))
    if partial and not analytic and not skyOnly then
      local maximumAlpha, fractional = 0, 0
      local curtainAlpha = 0
      for _, sample in expected[layer].values do
        maximumAlpha = math.max(maximumAlpha, sample.a)
        fractional += if sample.a > 1e-6 and sample.a < 1 - 1e-6 then 1 else 0
        if not scenario.miniature and not scenario.shared then
          curtainAlpha = math.max(curtainAlpha, sample.a - frame.visibility)
        end
      end
      assert(fractional > 0 and maximumAlpha < 1 - 1e-6, 'alpha is not hidden by opaque coverage; ' .. detail)
      if not scenario.miniature and not scenario.shared then
        print(string.format('aurora curtain alpha %s: peak contribution %.9g', scenario.name, curtainAlpha))
        assert(curtainAlpha > 1e-6, 'the reference exposes a curtain alpha contribution; ' .. detail)
      end
    end
    if analytic or skyOnly then
      assert(error.maximum <= ANALYTIC_ERROR, 'analytic-only branch; ' .. detail)
    else
      assert(error.maximum <= MAX_ERROR and error.mean <= MEAN_ERROR and error.rms <= RMS_ERROR, detail)
    end
    if skyOnly then
      assert(error.alpha <= SKY_ALPHA_ERROR, 'sky alpha remains unchanged; ' .. detail)
    elseif analytic then
      assert(error.alpha <= ANALYTIC_ERROR, 'analytic curtain alpha; ' .. detail)
    else
      assert(error.alpha <= ALPHA_MAX and error.alphaMean <= ALPHA_MEAN, 'curtain alpha budget; ' .. detail)
    end
    local summary = pixels.summary(image)
    if frame.visibility > 0 or scenario.miniature then
      assert(
        summary.alpha > (if scenario.miniature then 0.01 else 0.99 * frame.visibility),
        'nonempty coverage; ' .. detail
      )
      if frame.brightness > 0 or current.view > 0 then
        assert(summary.high > 0.001, 'nonblank RGB; ' .. detail)
      end
    end
  end
  if scenario.stereo then
    local difference = capture.metrics(actual[1], actual[2])
    local referenceDifference = capture.metrics(expected[1], expected[2])
    assert(referenceDifference.rms > 1e-7 and difference.rms > 1e-7, 'the two eye poses produce distinct images')
  end
  return { actual = actual[1], expected = expected[1] }
end

local function identical(a: Pair, b: Pair, label: string): ()
  local actual = capture.metrics(a.actual, b.actual)
  local expected = capture.metrics(a.expected, b.expected)
  assert(actual.maximum <= 1e-7 and actual.alpha <= 1e-7, 'production repeat is deterministic: ' .. label)
  assert(expected.maximum <= 1e-7 and expected.alpha <= 1e-7, 'reference repeat is deterministic: ' .. label)
end

local function refreshes(current: Fixture): ()
  local scenario: Scenario = { name = 'same Frame repeated', count = 17, age = 0.081, visibility = 0.45 }
  local frame = capture.observed(scenario)
  local first = compare(current, scenario, frame)
  identical(first, compare(current, scenario, frame), 'same Frame after submission')
  identical(first, compare(current, scenario), 'fresh Frame with identical clock and waves')
  local changed = compare(current, {
    name = 'same clock changed onset positions',
    count = 17,
    age = 0.081,
    shift = 0.09,
    visibility = 0.45,
  })
  capture.tracksChange(first, changed, 'fresh Frame with the same clock and changed waves')
  capture.tracksChange(changed, compare(current, scenario), 'same-clock waves recover')

  for _, clocks in
    {
      { 123 - 1 / 90, 123, 123 + 1 / 90 },
      { 4096 - 2 / 90, 4096 - 1 / 90, 0, 1 / 90 },
    }
  do
    local previous: Pair? = nil
    for index, time in clocks do
      local label = string.format('90 Hz t=%.9f', time)
      local pair = compare(current, { name = label, time = time, count = 17, age = 0.079 + (index - 1) / 90 })
      if previous then
        capture.tracksChange(previous, pair, label)
      end
      previous = pair
    end
  end

  local previous: Pair? = nil
  for _, age in { 0, 0.079, 0.081, 0.3, 0.7 } do
    local label = 'same-clock onset age ' .. age
    local pair = compare(current, { name = label, count = 17, age = age })
    if previous then
      capture.tracksChange(previous, pair, label)
    end
    previous = pair
  end
  local sparse = compare(current, { name = 'eight before cache', count = 8, age = 0.081, shift = 0.28 })
  local dense = compare(current, { name = 'nine enters cache', count = 9, age = 0.081, shift = 0.28 })
  capture.tracksChange(sparse, dense, '8/9 branch transition')
  capture.tracksChange(
    dense,
    compare(current, { name = 'eight after cache', count = 8, age = 0.081, shift = 0.28 }),
    '9/8 recovery'
  )
  local empty = compare(current, { name = 'empty before dense', count = 0 })
  compare(current, { name = 'full cache before empty', count = 34 })
  identical(empty, compare(current, { name = 'empty after dense', count = 0 }), 'empty after dense has no stale field')
end

local function coverage(current: Fixture): ()
  for _, count in { 0, 1, 3, 8, 9, 12, 17, 34 } do
    compare(current, { name = 'mixed source order ' .. count, count = count })
    compare(current, { name = 'reverse source order ' .. count, count = count, reverse = true, visibility = 0.4 })
  end
  local bands: { model.Band } = { 'bass', 'mid', 'treble' }
  for _, band in bands do
    local count = model.wavePools[band]
    compare(current, { name = 'isolated ' .. band, count = count, band = band, age = 0.081, visibility = 0.35 })
    compare(current, { name = 'isolated seam ' .. band, count = count, band = band, seam = true, angle = 'seam' })
  end
  for _, angle in { 'front', 'seam', 'side', 'up', 'down' } do
    compare(current, { name = 'dense angle ' .. angle, count = 34, angle = angle, seam = true })
  end
  for _, facing in { 0, 0.125, 0.75, 1 } do
    compare(current, { name = 'partial visibility facing ' .. facing, count = 17, visibility = 0.25, facing = facing })
  end
  compare(current, { name = 'dense zero brightness', count = 34, brightness = 0, visibility = 0.4 })
  compare(current, { name = 'invisible scene', count = 34, visibility = 0 })
  compare(current, { name = 'dense miniature', count = 34, miniature = true })
  compare(current, { name = 'hidden scene still has miniature', count = 17, miniature = true, visibility = 0 })
  compare(current, { name = 'scene and miniature share dense Frame', count = 34, shared = true, visibility = 0.3 })
  compare(current, { name = 'stereo scene', count = 17, stereo = true, visibility = 0.4 })
  compare(current, { name = 'stereo miniature', count = 34, stereo = true, miniature = true })
  compare(
    current,
    { name = 'stereo shared scene and miniature', count = 17, stereo = true, shared = true, visibility = 0.3 }
  )
  for view, name in DIAGNOSTICS do
    compare(current, { name = 'dense diagnostic ' .. name, count = 34, view = view, angle = 'up' })
  end
  local diagnostic: Scenario = { name = 'diagnostic then miniature in one pass', count = 17, view = 4, shared = true }
  local frame = capture.observed(diagnostic)
  compare(current, diagnostic, frame)
  compare(current, { name = 'normal miniature after diagnostic', count = 17, miniature = true }, frame)
end

test(
  'the shared curtain textures preserve the independent analytic renderer and refresh at frame boundaries',
  function(): ()
    capture.withFixture({}, function(current: Fixture): ()
      coverage(current)
      refreshes(current)
    end)
  end
)

test('curtain interpolation preserves monochrome and saturated palettes across all three focused layers', function(): ()
  local palettes = {
    {
      low = { 0.35, 0.35, 0.35 },
      high = { 0.6, 0.6, 0.6 },
      bass = { 1, 1, 1 },
      mid = { 1, 1, 1 },
      treble = { 1, 1, 1 },
    },
    {
      low = { 0.9, 0.02, 0.01 },
      high = { 0.01, 0.02, 0.95 },
      bass = { 1, 0, 0 },
      mid = { 0, 1, 0 },
      treble = { 0, 0, 1 },
    },
  }
  for index, palette in palettes do
    local input: config.Config = { palette = palette }
    capture.withFixture(input, function(current: Fixture): ()
      compare(current, { name = 'palette sparse ' .. index, count = 8 })
      compare(current, { name = 'palette cached ' .. index, count = 17, visibility = 0.4 })
      compare(current, { name = 'palette seam ' .. index, count = 34, seam = true, angle = 'seam' })
      compare(current, { name = 'palette miniature ' .. index, count = 34, miniature = true })
    end)
  end
end)

return test
