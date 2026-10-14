-- Each audio band draws in its own palette hue, both as its altitude's steady light and as an onset action.

local testing = require '@testing'
local aurora = require './support/aurora'
local pixels = require './support/pixels'
local render = require './support/render'
local shader = require '@lunette-plugins/desktop/backdrop/shader'
local model = require '@lunette-plugins/desktop/backdrop/model'
local config = require '@lunette-plugins/desktop/backdrop/config'
local test = testing.suite()

local ZERO: model.Features = { bass = 0, mid = 0, treble = 0, spectrum = { 0, 0, 0, 0, 0, 0, 0, 0 } }

local function snapshot(
  features: model.Features,
  onset: model.Onset?,
  age: number?,
  quality: ('low' | 'standard' | 'high')?
): pixels.ImageData
  local image: pixels.ImageData? = nil
  aurora.withFixture(
    { motion = 0, response = 1, fadeDuration = 5, quality = quality },
    function(current: aurora.Fixture): ()
      current.state:setFeatures(features)
      aurora.settle(current)
      current.state:setFeatures(features, if onset then { onset } else nil)
      aurora.update(current, age or 0.15)
      image = pixels.read(aurora.capture(current))
    end
  )
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

type FieldOptions = { layer: number?, onset: model.Onset?, visibility: number?, time: number?, brightness: number? }
type Capture = ({ number }, { number }?, number?, FieldOptions?) -> pixels.ImageData

-- A flat UV field isolates lighting from sky, geometry, and the model's coarse-band envelopes.
local function withField(run: (Capture) -> ()): ()
  local texture, pass = render.target(256, 128)
  local made: Shader? = nil
  local ok, failure = pcall(function(): ()
    made = lovr.graphics.newShader('fill', shader.curtainFragment)
    local function capture(
      spectrum: { number },
      stereo: { number }?,
      facing: number?,
      options: FieldOptions?
    ): pixels.ImageData
      local settings = options or {}
      local layer = settings.layer or 0
      pass:reset()
      pass:setCanvas { texture = texture, depth = false, samples = 1 }
      pass:setClear(0, 0, 0, 0)
      pass:setBlendMode(nil)
      pass:setShader(made)
      pass:send('backdropScene', { settings.visibility or 1, settings.time or 0, layer, 25 })
      pass:send('backdropResponse', { 0, 0, 0, settings.brightness or 1 })
      local focus = { 0.6, 0.6, 0.6, 0 }
      focus[layer + 1] = 1.6
      pass:send('backdropFocus', focus)
      pass:send('backdropSpectrum', { { unpack(spectrum, 1, 4) }, { unpack(spectrum, 5, 8) } })
      local sides = stereo or { 0, 0, 0, 0, 0, 0, 0, 0 }
      pass:send('backdropStereo', { { unpack(sides, 1, 4) }, { unpack(sides, 5, 8) } })
      pass:send('backdropFacing', { facing or 0.5, 0, 0, 0 })
      for _, name in { 'low', 'high', 'bass', 'mid', 'treble' } do
        pass:send('backdrop' .. string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2), PALETTE[name])
      end
      local waves, details = {}, {}
      for index = 1, model.MAX_WAVES do
        waves[index], details[index] = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
      end
      local onset = settings.onset
      if onset then
        local band = if onset.band == 'bass' then 1 elseif onset.band == 'treble' then 3 else 2
        waves[1] = { onset.age or 0.15, onset.strength, onset.position or 0.5, band }
        details[1] = { onset.frequency or 0.5, 0, 0, 0 }
      end
      pass:send('backdropWaves', waves)
      pass:send('backdropWaveDetail', details)
      pass:fill()
      return pixels.read(render.read(texture, pass))
    end
    run(capture)
  end)
  pass:release()
  if made then
    made:release()
  end
  texture:release()
  assert(ok, failure)
end

local function addedField(baseline: pixels.ImageData, image: pixels.ImageData): pixels.ImageData
  local values = {}
  for index, p in image.values do
    local q = baseline.values[index]
    values[index] = { r = math.max(0, p.r - q.r), g = math.max(0, p.g - q.g), b = math.max(0, p.b - q.b), a = 0 }
  end
  return { width = image.width, height = image.height, values = values }
end

local function sideCentroid(image: pixels.ImageData, facing: number): number
  local weight, moment = 0, 0
  for index, p in image.values do
    local total = p.r + p.g + p.b
    local longitude = (((index - 1) % image.width) + 0.5) / image.width
    weight += total
    moment += total * -math.sin(2 * math.pi * (longitude - facing))
  end
  return moment / math.max(weight, 1e-9)
end

test('hard stereo moves the added light toward the matching head-relative side', function(): ()
  withField(function(capture: Capture): ()
    local spectrum = { 0, 0, 0, 0, 0.65, 0, 0, 0 }
    local left = { 0, 0, 0, 0, -0.65, 0, 0, 0 }
    local right = { 0, 0, 0, 0, 0.65, 0, 0, 0 }
    local baseline = capture(ZERO.spectrum)
    for _, facing in { 0.5, 0.125 } do
      local neutral = sideCentroid(addedField(baseline, capture(spectrum, nil, facing)), facing)
      local l = sideCentroid(addedField(baseline, capture(spectrum, left, facing)), facing) - neutral
      local r = sideCentroid(addedField(baseline, capture(spectrum, right, facing)), facing) - neutral
      print('aurora stereo centroid', facing, l, r)
      testing.expect.truthy(l < -0.2 and r > 0.2, 'left and right move in opposite directions')
      testing.expect.truthy(math.abs(l + r) < 0.18, 'swapping channels mirrors the weighted displacement')
    end
  end)
end)

test('adjacent spectrum bands within each coarse band retain distinct altitude and shape', function(): ()
  withField(function(capture: Capture): ()
    local baseline = capture(ZERO.spectrum)
    local images, centroids = {}, {}
    for band = 1, 8 do
      local spectrum = { 0, 0, 0, 0, 0, 0, 0, 0 }
      spectrum[band] = 0.8
      local image = capture(spectrum)
      images[band] = addedField(baseline, image)
      centroids[band] = pixels.added(baseline, image).y
      testing.expect.truthy(pixels.summary(images[band]).mean > 1e-4, 'each band adds measurable light')
    end
    for _, band in { 1, 2, 4, 5, 7 } do
      local difference = pixels.difference(images[band], images[band + 1])
      print('aurora adjacent bands', band, centroids[band], centroids[band + 1], difference.shape)
      testing.expect.truthy(centroids[band + 1] - centroids[band] > 0.018, 'adjacent bands occupy higher UV zones')
      testing.expect.truthy(difference.shape > 8e-4, 'adjacent bands differ beyond their total brightness')
    end
  end)
end)

test('onset frequency changes altitude and focuses its layer without following head rotation', function(): ()
  withField(function(capture: Capture): ()
    for index, band in { 'bass', 'mid', 'treble' } :: { model.Band } do
      local layer = index - 1
      local baseline = capture(ZERO.spectrum, nil, nil, { layer = layer })
      local onset: model.Onset = { band = band, strength = 0.7, age = 0.15, position = 0.63, frequency = 0 }
      local low = capture(ZERO.spectrum, nil, 0.5, { layer = layer, onset = onset })
      onset = { band = band, strength = 0.7, age = 0.15, position = 0.63, frequency = 1 }
      local high = capture(ZERO.spectrum, nil, 0.5, { layer = layer, onset = onset })
      local lowAdded, highAdded = pixels.added(baseline, low), pixels.added(baseline, high)
      testing.expect.truthy(highAdded.y - lowAdded.y > 0.035, band .. ' centroid raises the onset zone')
      testing.expect.truthy(
        pixels.difference(addedField(baseline, low), addedField(baseline, high)).shape > 1e-4,
        band .. ' centroid changes the onset shape'
      )
      local turned = capture(ZERO.spectrum, nil, 0.125, { layer = layer, onset = onset })
      testing.expect.equal(pixels.difference(high, turned).color, 0, 'head rotation does not move an onset')
      local other = index % 3
      local otherBase = capture(ZERO.spectrum, nil, nil, { layer = other })
      local otherLit = capture(ZERO.spectrum, nil, nil, { layer = other, onset = onset })
      local focused = pixels.summary(addedField(baseline, high)).mean
      local unfocused = pixels.summary(addedField(otherBase, otherLit)).mean
      testing.expect.truthy(focused > unfocused * 1.8, band .. ' onset favors its matching curtain layer')
    end
  end)
end)

test('curtain output remains bounded, fades proportionally, and repeats at the motion clock wrap', function(): ()
  withField(function(capture: Capture): ()
    local spectrum = { 1, 1, 1, 1, 1, 1, 1, 1 }
    local full = capture(spectrum, nil, nil, { brightness = 4 })
    local faded = capture(spectrum, nil, nil, { brightness = 4, visibility = 0.25 })
    local wrapped = capture(spectrum, nil, nil, { brightness = 4, time = 4096 })
    testing.expect.truthy(pixels.difference(full, wrapped).color < 1e-4, 'the motion clock wraps without a jump')
    for index, p in full.values do
      local q = faded.values[index]
      for _, channel in { 'r', 'g', 'b', 'a' } do
        testing.expect.truthy(p[channel] >= 0 and p[channel] <= 1, 'light stays within the output bounds')
        testing.expect.near(q[channel], p[channel] * 0.25, 2 / 255, 'the premultiplied output fades together')
      end
    end
  end)
end)

test('silence and dense spectrum retain light variation and curtain gaps', function(): ()
  withField(function(capture: Capture): ()
    for _, spectrum in { ZERO.spectrum, { 1, 1, 1, 1, 1, 1, 1, 1 } } do
      local image = capture(spectrum)
      local summary = pixels.summary(image)
      local dark, bright = 0, 0
      for x = 0, image.width - 1 do
        local total = 0
        for y = 0, image.height - 1 do
          local p = pixels.at(image, x, y)
          total += p.r + p.g + p.b
        end
        local mean = total / image.height
        dark += if mean < 0.003 then 1 else 0
        bright += if mean > 0.015 then 1 else 0
      end
      testing.expect.truthy(summary.high - summary.low > 0.03, 'the field has visible texture at rest and full energy')
      testing.expect.truthy(dark > image.width * 0.05 and bright > image.width * 0.2, 'dark gaps survive dense energy')
    end
  end)
end)

test('all geometry qualities render stereo energy and localized onsets', function(): ()
  local dense: model.Features = {
    bass = 0.5,
    mid = 0.5,
    treble = 0.5,
    spectrum = { 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 },
    stereo = { -0.5, -0.5, -0.5, 0, 0, 0, 0.5, 0.5 },
  }
  for _, quality in { 'low', 'standard', 'high' } do
    local baseline = snapshot(ZERO, nil, nil, quality)
    local active = snapshot(dense, { strength = 1, band = 'treble', position = 0.4, frequency = 1 }, nil, quality)
    testing.expect.truthy(pixels.summary(baseline).nonblank > 0.5, quality .. ' autonomous sky renders')
    testing.expect.truthy(
      pixels.difference(baseline, active).shape > 1e-4,
      quality .. ' stereo and onset response renders'
    )
  end
end)

return test
