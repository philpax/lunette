local testing = require '@testing'
local expect = testing.expect
local features = require '../features'
local test = testing.suite()

type Hop = features.Hop
type Band = 'bass' | 'mid' | 'treble'
type Oracle = {
  bassPower: number,
  midPower: number,
  treblePower: number,
  rms: number,
  peak: number,
}

local function pcm(size: number, sample: (number) -> (number, number)): buffer
  local result = buffer.create(size * 8)
  for frame = 0, size - 1 do
    local left, right = sample(frame)
    buffer.writef32(result, frame * 8, left)
    buffer.writef32(result, frame * 8 + 4, right)
  end
  return result
end

local function analyse(samples: buffer, size: number): Hop
  local analyser = features.new { size = size }
  analyser:beginFrame()
  return analyser:feed(samples, { frameCount = size, generation = 1, sequence = 1, startFrame = 0 }).hops[1]
end

-- This oracle evaluates the DFT directly rather than using the transform, its window, or its band lookup.
local function oracle(samples: buffer, size: number): (Oracle, { [number]: number })
  local squaredWindow, squares, peak = 0, 0, 0
  for sample = 0, size - 1 do
    local w = (1 - math.cos(2 * math.pi * sample / size)) / 2
    squaredWindow += w ^ 2
    for channel = 0, 1 do
      local value = buffer.readf32(samples, sample * 8 + channel * 4)
      squares += value ^ 2
      peak = math.max(peak, math.abs(value))
    end
  end
  local bandPower: { [Band]: number } = { bass = 0, mid = 0, treble = 0 }
  local magnitudes = {}
  for bin = 0, size / 2 do
    local power = 0
    for channel = 0, 1 do
      local real, imag = 0, 0
      for sample = 0, size - 1 do
        local value = buffer.readf32(samples, sample * 8 + channel * 4)
        local window = (1 - math.cos(2 * math.pi * sample / size)) / 2
        local angle = 2 * math.pi * bin * sample / size
        real += value * window * math.cos(angle)
        imag -= value * window * math.sin(angle)
      end
      power += (real ^ 2 + imag ^ 2) / (2 * size * squaredWindow)
    end
    if bin > 0 and bin < size / 2 then
      power *= 2
    end
    local frequency = bin * 48000 / size
    local band = if frequency >= 30 and frequency < 250
      then 'bass'
      elseif frequency >= 250 and frequency < 2000 then 'mid'
      elseif frequency >= 2000 and frequency < 10000 then 'treble'
      else nil
    if band then
      bandPower[band] += power
      magnitudes[bin] = math.sqrt(power)
    end
  end
  return {
    bassPower = bandPower.bass,
    midPower = bandPower.mid,
    treblePower = bandPower.treble,
    rms = math.sqrt(squares / (2 * size)),
    peak = peak,
  },
    magnitudes
end

test('audio_features_known_signals', function()
  for _, size in { 512, 1024, 2048 } do
    local silence = analyse(
      pcm(size, function(): (number, number)
        return 0, 0
      end),
      size
    )
    for _, key in { 'bassPower', 'midPower', 'treblePower', 'rms', 'peak', 'flux', 'onset' } do
      expect.equal(silence[key], 0, 'silence ' .. key)
    end
    for _, tone in
      { { bin = 3, band = 'bass', size = 2048 }, { bin = 16, band = 'mid' }, { bin = 96, band = 'treble' } }
    do
      if tone.size == nil or tone.size == size then
        local inPhase = analyse(
          pcm(size, function(frame: number): (number, number)
            local value = 0.5 * math.sin(2 * math.pi * tone.bin * frame / size)
            return value, value
          end),
          size
        )
        local antiPhase = analyse(
          pcm(size, function(frame: number): (number, number)
            local value = 0.5 * math.sin(2 * math.pi * tone.bin * frame / size)
            return value, -value
          end),
          size
        )
        expect.near(
          math.sqrt(inPhase[tone.band .. 'Power']),
          0.5 / math.sqrt(2),
          1e-7,
          'the tone band RMS ' .. size .. ' ' .. tone.band
        )
        expect.near(inPhase.rms, 0.5 / math.sqrt(2), 1e-7, 'the unweighted RMS')
        for _, key in { 'bassPower', 'midPower', 'treblePower', 'rms', 'peak' } do
          expect.near(antiPhase[key], inPhase[key], 1e-12, 'anti-phase power does not cancel')
        end
      end
    end
    local oneChannel = analyse(
      pcm(size, function(frame: number): (number, number)
        return 0.5 * math.sin(2 * math.pi * 16 * frame / size), 0
      end),
      size
    )
    expect.near(math.sqrt(oneChannel.midPower), 0.25, 1e-7, 'channel powers are averaged')
    expect.near(oneChannel.rms, 0.25, 1e-7, 'stereo RMS averages both channels')
    local dc = analyse(
      pcm(size, function(): (number, number)
        return 0.5, -0.5
      end),
      size
    )
    expect.equal(dc.rms, 0.5, 'DC unweighted RMS')
    expect.equal(dc.peak, 0.5, 'DC peak')
    local dcSideBin = if size == 2048 then 0 else 0.5 / math.sqrt(3)
    expect.near(math.sqrt(dc.bassPower), dcSideBin, 1e-10, 'the periodic Hann side bin follows bass bin membership')
    local nyquist = analyse(
      pcm(size, function(frame: number): (number, number)
        return (-1) ^ frame * 0.5, 0
      end),
      size
    )
    expect.near(nyquist.rms, 0.5 / math.sqrt(2), 1e-10, 'Nyquist unweighted RMS')
    expect.near(
      math.sqrt(nyquist.bassPower) + math.sqrt(nyquist.midPower) + math.sqrt(nyquist.treblePower),
      0,
      1e-10,
      'Nyquist is outside the bands'
    )
  end
end)

test('stereo random boundary tones and impulses agree with an independent DFT oracle', function()
  local size = 512
  local seed = 6571
  local function random(): number
    seed = seed * 48271 % 2147483647
    return seed / 2147483647 - 0.5
  end
  local signals = {
    pcm(size, function(): (number, number)
      return random(), random()
    end),
    pcm(size, function(frame: number): (number, number)
      return if frame == 173 then 1 else 0, if frame == 97 then -0.5 else 0
    end),
  }
  -- Adjacent bins straddle each half-open band edge at this size.
  for _, bin in { 0, 1, 2, 3, 21, 22, 106, 107, 256 } do
    table.insert(
      signals,
      pcm(size, function(frame: number): (number, number)
        local value = 0.3 * math.cos(2 * math.pi * bin * frame / size)
        return value, -0.5 * value
      end)
    )
  end
  for _, samples in signals do
    local wanted = oracle(samples, size)
    local actual = analyse(samples, size)
    for _, key in { 'bassPower', 'midPower', 'treblePower', 'rms', 'peak' } do
      expect.near(actual[key], wanted[key], 1e-10, 'the independent stereo DFT ' .. key)
    end
  end
end)

test('flux onset and silence suppression agree with independent window spectra', function()
  local size = 512
  local analyser = features.new { size = size, hop = size / 2 }
  local function rising(frame: number): (number, number)
    local amplitude = if frame < size then 0.05 else 0.2
    local value = amplitude * math.sin(2 * math.pi * 12 * frame / size)
    return value, -value
  end
  local samples = pcm(size + size / 2, rising)
  local batch = analyser:feed(samples, { frameCount = size + size / 2, generation = 1, sequence = 1, startFrame = 0 })
  expect.equal(#batch.hops, 2, 'two complete windows')
  local first, second = buffer.create(size * 8), buffer.create(size * 8)
  buffer.copy(first, 0, samples, 0, size * 8)
  buffer.copy(second, 0, samples, size / 2 * 8, size * 8)
  local _, previous = oracle(first, size)
  local _, current = oracle(second, size)
  local positive, sum = 0, 0
  for bin, magnitude in previous do
    sum += magnitude
    positive += math.max(0, current[bin] - magnitude)
  end
  local flux = math.min(1, positive / math.max(sum, 0.001))
  expect.equal(batch.hops[1].flux, 0, 'the first window establishes history')
  expect.near(batch.hops[2].flux, flux, 1e-10, 'positive spectral flux')
  expect.near(batch.hops[2].onset, math.clamp((flux - 0.08) / 0.24, 0, 1), 1e-10, 'the onset threshold')
  local quiet = features.new { size = size }
  local quietPcm = pcm(size * 2, function(frame: number): (number, number)
    local value = if frame < size then 0 else 0.0005 * math.sin(2 * math.pi * 12 * frame / size)
    return value, value
  end)
  for _, hop in quiet:feed(quietPcm, { frameCount = size * 2, generation = 1, sequence = 1, startFrame = 0 }).hops do
    expect.equal(hop.flux, 0, 'quiet flux suppression')
    expect.equal(hop.onset, 0, 'quiet onset suppression')
  end
end)

return test
