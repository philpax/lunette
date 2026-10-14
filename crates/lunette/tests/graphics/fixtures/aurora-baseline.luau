-- Rasterizes the exact production sky and curtains through the production base consumer.

local testing = require '@testing'
local aurora = require './support/aurora'
local pixels = require './support/pixels'
local model = require '@lunette-plugins/environment/backdrop/private/rendering/model'
local test = testing.suite()

local function snapshot(features: model.Features, onset: model.Onset?): pixels.ImageData
  local image: pixels.ImageData? = nil
  aurora.withFixture({ motion = 0, response = 1, fadeDuration = 5 }, function(current: aurora.Fixture): ()
    current.state:setFeatures(features)
    aurora.settle(current)
    if onset then
      current.state:setFeatures(features, { onset })
      aurora.update(current, 0.15)
    else
      aurora.update(current, 0.15)
    end
    image = pixels.read(aurora.capture(current))
  end)
  assert(image, 'production snapshot was not captured')
  return image
end

test('aurora_baseline_and_band_response_pixels', function(): ()
  local zero = { bass = 0, mid = 0, treble = 0 }
  local baseline = snapshot(zero)
  local summary = pixels.summary(baseline)
  print('aurora baseline', summary.nonblank, summary.low, summary.high, summary.mean, summary.alpha)
  testing.expect.truthy(summary.nonblank > 0.5, 'autonomous sky is nonblank without audio')
  testing.expect.truthy(summary.high - summary.low > 0.05, 'curtains vary spatially')
  for _, band in { 'bass', 'mid', 'treble' } do
    local features = table.clone(zero)
    features[band] = 1
    local difference = pixels.difference(baseline, snapshot(features))
    print('aurora band', band, difference.alpha, difference.color, difference.shape, difference.changed)
    testing.expect.truthy(difference.shape > 0.0001, band .. ' changes more than uniform brightness')
    testing.expect.truthy(difference.changed > 0.0001, band .. ' changes curtain coverage')
  end
  local onset = snapshot(zero, { strength = 1, position = 0.5 })
  local moved = snapshot(zero, { strength = 1, position = 0.6 })
  local first, second = pixels.difference(baseline, onset), pixels.difference(baseline, moved)
  print('aurora onset', first.alpha, first.changed, first.x, second.alpha, second.changed, second.x)
  testing.expect.truthy(first.changed > 0.0001, 'an onset changes a spatial alpha mask')
  testing.expect.truthy(math.abs(first.x - second.x) > 0.05, 'onset position moves the response across the view')
end)

return test
