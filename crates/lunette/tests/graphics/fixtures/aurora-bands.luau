-- Each audio band draws in its own palette hue, both as steady spectrum light and as an onset action.

local testing = require '@testing'
local aurora = require './support/aurora'
local pixels = require './support/pixels'
local model = require '@lunette-plugins/desktop/backdrop/model'
local test = testing.suite()

local ZERO: model.Features = { bass = 0, mid = 0, treble = 0, spectrum = { 0, 0, 0, 0, 0, 0, 0, 0 } }

local function snapshot(features: model.Features, onset: model.Onset?, age: number?): pixels.ImageData
  local image: pixels.ImageData? = nil
  aurora.withFixture({ motion = 0, response = 1, fadeDuration = 5 }, function(current: aurora.Fixture): ()
    current.state:setFeatures(features)
    aurora.settle(current)
    current.state:setFeatures(features, if onset then { onset } else nil)
    aurora.update(current, age or 0.15)
    image = pixels.read(aurora.capture(current))
  end)
  assert(image, 'production snapshot was not captured')
  return image
end

local function strongest(added: pixels.Added): string
  if added.r >= added.g and added.r >= added.b then
    return 'r'
  end
  return if added.g >= added.b then 'g' else 'b'
end

-- The channel that grows most relative to the baseline's own mix. Displacement moves existing curtain colour
-- into new pixels, so absolute added light would measure the palette's base gradient rather than the tint.
local function dominant(added: pixels.Added, baseline: pixels.ImageData): string
  local r, g, b = 0, 0, 0
  for _, sample in baseline.values do
    r += sample.r
    g += sample.g
    b += sample.b
  end
  local count = #baseline.values
  local shares = { r = added.r / (r / count), g = added.g / (g / count), b = added.b / (b / count) }
  if shares.r >= shares.g and shares.r >= shares.b then
    return 'r'
  end
  return if shares.g >= shares.b then 'g' else 'b'
end

test('band onsets add light in their own palette hue', function(): ()
  local baseline = snapshot(ZERO)
  for band, channel in { bass = 'r', mid = 'g', treble = 'b' } do
    -- Treble glints each twinkle briefly at their own moment, so every band sums its light across its life.
    local added: pixels.Added = { r = 0, g = 0, b = 0, y = 0 }
    for step = 1, 8 do
      local onset: model.Onset = { strength = 1, position = 0.5, band = band :: model.Band }
      -- Visibility is still fading in, so each age compares against a baseline of the same age.
      local age = model.waveLifetimes[band :: model.Band] * step / 9
      local sample = pixels.added(snapshot(ZERO, nil, age), snapshot(ZERO, onset, age))
      added.r += sample.r
      added.g += sample.g
      added.b += sample.b
    end
    print('aurora onset hue', band, added.r, added.g, added.b)
    -- Treble glints cover under a pixel each at this resolution, so the bar only excludes no light at all.
    testing.expect.truthy(added.r + added.g + added.b > 1e-6, band .. ' onset adds visible light')
    testing.expect.equal(dominant(added, baseline), channel, band .. ' onset hue')
  end
end)

test('the curtain height is a spectrum from low bands below to high bands above', function(): ()
  local baseline = snapshot(ZERO)
  local function lit(band: number): pixels.Added
    local spectrum = { 0, 0, 0, 0, 0, 0, 0, 0 }
    spectrum[band] = 1
    return pixels.added(baseline, snapshot { bass = 0, mid = 0, treble = 0, spectrum = spectrum })
  end
  local low, middle, high = lit(1), lit(5), lit(8)
  print(
    'aurora spectrum',
    low.r,
    low.g,
    low.b,
    low.y,
    middle.r,
    middle.g,
    middle.b,
    middle.y,
    high.r,
    high.g,
    high.b,
    high.y
  )
  testing.expect.equal(strongest(low), 'r', 'the lowest band lights in the bass hue')
  testing.expect.equal(strongest(middle), 'g', 'a middle band lights in the mid hue')
  testing.expect.equal(strongest(high), 'b', 'the highest band lights in the treble hue')
  testing.expect.truthy(low.y > middle.y and middle.y > high.y, 'higher bands light higher on the curtain')
end)

return test
