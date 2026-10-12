-- Each audio band draws in its own palette hue, both as its altitude's steady light and as an onset action.

local testing = require '@testing'
local aurora = require './support/aurora'
local pixels = require './support/pixels'
local model = require '@lunette-plugins/desktop/backdrop/model'
local config = require '@lunette-plugins/desktop/backdrop/config'
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

local PALETTE = config.schema.parse({}).palette

-- The band whose configured colour points most nearly the same way as the added light, by cosine similarity.
-- Palette hues are not primaries, so the dominant channel would misclassify violet treble light as red.
local function nearest(added: pixels.Added): model.Band
  local best: model.Band, score = 'bass', -math.huge
  local length = math.sqrt(added.r ^ 2 + added.g ^ 2 + added.b ^ 2)
  for _, band in { 'bass', 'mid', 'treble' } :: { model.Band } do
    local colour = PALETTE[band]
    local dot = added.r * colour[1] + added.g * colour[2] + added.b * colour[3]
    local similarity = dot / math.max(length * math.sqrt(colour[1] ^ 2 + colour[2] ^ 2 + colour[3] ^ 2), 1e-12)
    if similarity > score then
      best, score = band, similarity
    end
  end
  return best
end

test('band onsets add light in their own palette hue', function(): ()
  for _, band in { 'bass', 'mid', 'treble' } :: { model.Band } do
    -- Treble glints each twinkle briefly at their own moment, so every band sums its light across its life.
    local added: pixels.Added = { r = 0, g = 0, b = 0, y = 0 }
    for step = 1, 8 do
      local onset: model.Onset = { strength = 1, position = 0.5, band = band }
      -- Visibility is still fading in, so each age compares against a baseline of the same age.
      local age = model.waveLifetimes[band] * step / 9
      local sample = pixels.added(snapshot(ZERO, nil, age), snapshot(ZERO, onset, age))
      added.r += sample.r
      added.g += sample.g
      added.b += sample.b
    end
    print('aurora onset hue', band, added.r, added.g, added.b)
    -- Treble glints cover under a pixel each at this resolution, so the bar only excludes no light at all.
    testing.expect.truthy(added.r + added.g + added.b > 1e-6, band .. ' onset adds visible light')
    testing.expect.equal(nearest(added), band, band .. ' onset hue')
  end
end)

test('each band lights its own altitude, from the hem for bass to the ray tops for treble', function(): ()
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
  testing.expect.equal(nearest(low), 'bass', 'the lowest band lights in the bass hue')
  testing.expect.equal(nearest(middle), 'mid', 'a middle band lights in the mid hue')
  testing.expect.equal(nearest(high), 'treble', 'the highest band lights in the treble hue')
  testing.expect.truthy(low.y > middle.y and middle.y > high.y, 'higher bands light higher on the curtains')
end)

return test
