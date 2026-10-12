local testing = require '@testing'
local expect = testing.expect
local features = require '../features'
local test = testing.suite()

type Hop = features.Hop

-- Feeds mono samples in render-sized blocks, as the provider does, and returns every completed hop.
local function hops(size: number, frames: number, sample: (number) -> number): { Hop }
  local analyser = features.new { size = size }
  local result: { Hop } = {}
  local block = 4800
  for index = 0, frames // block - 1 do
    analyser:beginFrame()
    local pcm = buffer.create(block * 8)
    for frame = 0, block - 1 do
      local value = sample(index * block + frame)
      buffer.writef32(pcm, frame * 8, value)
      buffer.writef32(pcm, frame * 8 + 4, value)
    end
    local metadata = { frameCount = block, generation = 1, sequence = index + 1, startFrame = index * block }
    for _, hop in analyser:feed(pcm, metadata).hops do
      table.insert(result, hop)
    end
  end
  return result
end

local function noise(seed: number): () -> number
  local state = seed
  return function(): number
    state = (state * 1103515245 + 12345) % 2147483648
    return state / 2147483648 * 2 - 1
  end
end

local function peaks(list: { Hop }): (number, number, number)
  local bass, mid, treble = 0, 0, 0
  for _, hop in list do
    bass, mid, treble = math.max(bass, hop.bassOnset), math.max(mid, hop.midOnset), math.max(treble, hop.trebleOnset)
  end
  return bass, mid, treble
end

test('the eight spectrum bands partition the three coarse bands at every size', function()
  for _, size in { 512, 1024, 2048 } do
    for seed = 1, 4 do
      local random = noise(seed)
      local phase = seed * 0.37
      for _, hop in
        hops(size, 9600, function(frame: number): number
          return random() * 0.2 + math.sin(phase + frame * seed * 0.011) * 0.3
        end)
      do
        local spectrum = hop.spectrum
        expect.equal(#spectrum, features.SPECTRUM_BANDS, 'eight bands')
        local bass, mid, treble =
          spectrum[1] + spectrum[2] + spectrum[3], spectrum[4] + spectrum[5] + spectrum[6], spectrum[7] + spectrum[8]
        expect.near(bass, hop.bassPower, 1e-12 + hop.bassPower * 1e-9, 'bass bands sum to bass power')
        expect.near(mid, hop.midPower, 1e-12 + hop.midPower * 1e-9, 'mid bands sum to mid power')
        expect.near(treble, hop.treblePower, 1e-12 + hop.treblePower * 1e-9, 'treble bands sum to treble power')
      end
    end
  end
end)

test('a tone lights the spectrum band that contains it', function()
  for band, frequency in { 45, 90, 180, 350, 700, 1400, 2800, 6000 } do
    local list = hops(2048, 9600, function(frame: number): number
      return math.sin(2 * math.pi * frequency * frame / 48000) * 0.5
    end)
    local spectrum = list[#list].spectrum
    local loudest = 1
    for index, power in spectrum do
      if power > spectrum[loudest] then
        loudest = index
      end
    end
    expect.equal(loudest, band, frequency .. ' Hz band')
  end
end)

test('band onsets separate kicks from hi-hats and ignore steady noise', function()
  local random = noise(7)
  local kick = hops(2048, 96000, function(frame: number): number
    local t = (frame % 24000) / 48000
    return math.sin(2 * math.pi * 55 * t) * math.exp(-t * 12) * 0.6 + random() * 0.01
  end)
  local bass, _, treble = peaks(kick)
  expect.equal(bass, 1, 'a kick saturates the bass onset')
  expect.equal(treble, 0, 'a kick leaves the treble onset silent')

  local previous = 0
  local hat = hops(2048, 96000, function(frame: number): number
    local t = (frame % 6000) / 48000
    local value = random()
    local high = value - previous
    previous = value
    return math.sin(2 * math.pi * 220 * frame / 48000) * 0.3 + high * math.exp(-t * 80) * 0.3
  end)
  bass, _, treble = peaks(hat)
  expect.equal(treble, 1, 'a hi-hat saturates the treble onset')
  expect.equal(bass, 0, 'a hi-hat leaves the bass onset silent')

  for _, scale in { 0.3, 0.003 } do
    local steady = hops(2048, 96000, function(): number
      return random() * scale
    end)
    local quiet, middle, high = peaks(steady)
    expect.truthy(quiet < 0.25 and middle < 0.25 and high < 0.25, 'steady noise stays below a quarter onset')
  end
end)

test('band onsets are zero on the first window and below the silence floor', function()
  local first = hops(2048, 4800, function(frame: number): number
    return if frame % 4000 < 40 then 0.9 else 0
  end)
  expect.equal(first[1].bassOnset + first[1].midOnset + first[1].trebleOnset, 0, 'first window is a baseline')
  local silent = hops(2048, 9600, function(frame: number): number
    return if frame % 2000 < 4 then 0.0005 else 0
  end)
  for _, hop in silent do
    expect.equal(hop.bassOnset + hop.midOnset + hop.trebleOnset, 0, 'below RMS 0.001 there is no onset')
  end
end)

test('band onset mapping is monotonic and bounded', function()
  local last = 0
  for step = 0, 100 do
    local value = features.bandOnset(step / 100)
    expect.truthy(value >= last and value >= 0 and value <= 1, 'monotonic and bounded')
    last = value
  end
  expect.equal(features.bandOnset(0.3), 0, 'floor')
  expect.equal(features.bandOnset(0.71), 1, 'saturation')
end)

return test
