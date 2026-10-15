local testing = require '@testing'
local expect = testing.expect
local features = require '../private/features'
local test = testing.suite()

type Hop = features.Hop

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

local function tone(frame: number, size: number, bin: number, amplitude: number): number
  return amplitude * math.sin(2 * math.pi * bin * frame / size)
end

test('hard left and right retain full channel power rather than half contributions', function()
  for _, size in { 512, 1024, 2048 } do
    local toneBand = if size == 512 then 6 elseif size == 1024 then 5 else 4
    for _, channel in { 'left', 'right' } do
      local hop = analyse(
        pcm(size, function(frame: number): (number, number)
          local value = tone(frame, size, 16, 0.5)
          return if channel == 'left' then value else 0, if channel == 'right' then value else 0
        end),
        size
      )
      local audible = if channel == 'left' then hop.leftSpectrum else hop.rightSpectrum
      local silent = if channel == 'left' then hop.rightSpectrum else hop.leftSpectrum
      expect.equal(#audible, 8, 'eight audible channel bands')
      expect.equal(#silent, 8, 'eight silent channel bands')
      for band = 1, 8 do
        expect.near(audible[band], if band == toneBand then 0.125 else 0, 1e-8, 'full channel mean square')
        expect.equal(silent[band], 0, 'the other channel stays silent')
        expect.near(hop.spectrum[band], audible[band] / 2, 1e-12, 'combined power averages the silent channel')
      end
      expect.near(hop.rms, 0.25, 1e-8, 'stereo RMS still averages the silent channel')
      expect.equal(hop.peak, 0.5, 'peak still includes the audible channel')
    end
  end
end)

test('distinct simultaneous channel frequencies remain in their own spectrum bands', function()
  for _, size in { 512, 1024, 2048 } do
    local leftBand = if size == 512 then 6 elseif size == 1024 then 5 else 4
    local rightBand = if size == 2048 then 7 else 8
    local hop = analyse(
      pcm(size, function(frame: number): (number, number)
        return tone(frame, size, 16, 0.5), tone(frame, size, 96, 0.25)
      end),
      size
    )
    for band = 1, 8 do
      expect.near(hop.leftSpectrum[band], if band == leftBand then 0.125 else 0, 1e-8, 'left frequency power')
      expect.near(hop.rightSpectrum[band], if band == rightBand then 0.03125 else 0, 1e-8, 'right frequency power')
      local wanted = if band == leftBand then 0.0625 elseif band == rightBand then 0.015625 else 0
      expect.near(hop.spectrum[band], wanted, 1e-8, 'both frequencies remain in the combined spectrum')
    end
  end
end)

test('identical and inverted channels have equal per-channel and combined power', function()
  for _, size in { 512, 1024, 2048 } do
    local function sample(frame: number): number
      return tone(frame, size, 16, 0.4) + tone(frame, size, 96, 0.2)
    end
    local identical = analyse(
      pcm(size, function(frame: number): (number, number)
        local value = sample(frame)
        return value, value
      end),
      size
    )
    local inverted = analyse(
      pcm(size, function(frame: number): (number, number)
        local value = sample(frame)
        return value, -value
      end),
      size
    )
    for _, field in { 'spectrum', 'leftSpectrum', 'rightSpectrum' } do
      for band = 1, 8 do
        expect.near(inverted[field][band], identical[field][band], 1e-12, 'phase inversion does not cancel power')
        expect.near(identical[field][band], identical.spectrum[band], 1e-12, 'identical channels carry full power')
      end
    end
    for _, field in
      { 'bassPower', 'midPower', 'treblePower', 'rms', 'peak', 'flux', 'onset', 'bassOnset', 'midOnset', 'trebleOnset' }
    do
      expect.near(inverted[field], identical[field], 1e-12, 'phase inversion preserves ' .. field)
    end
  end
end)

test('every combined band averages channel powers and agrees with separate mono analyses', function()
  for _, size in { 512, 1024, 2048 } do
    for seed = 1, 4 do
      local state = seed * 6571
      local function random(): number
        state = state * 48271 % 2147483647
        return state / 2147483647 - 0.5
      end
      local stereo = pcm(size, function(): (number, number)
        return random() * 0.8, random() * 0.3
      end)
      local paired = analyse(stereo, size)
      local left = analyse(
        pcm(size, function(frame: number): (number, number)
          local value = buffer.readf32(stereo, frame * 8)
          return value, value
        end),
        size
      )
      local right = analyse(
        pcm(size, function(frame: number): (number, number)
          local value = buffer.readf32(stereo, frame * 8 + 4)
          return value, value
        end),
        size
      )
      for band = 1, 8 do
        expect.near(paired.leftSpectrum[band], left.spectrum[band], 1e-12, 'left agrees with independent mono input')
        expect.near(paired.rightSpectrum[band], right.spectrum[band], 1e-12, 'right agrees with independent mono input')
        expect.near(
          paired.spectrum[band],
          (left.spectrum[band] + right.spectrum[band]) / 2,
          1e-12,
          'combined agrees with the mono reference average'
        )
        expect.near(
          paired.spectrum[band],
          (paired.leftSpectrum[band] + paired.rightSpectrum[band]) / 2,
          1e-12,
          'the published band is the arithmetic channel average'
        )
      end
    end
  end
end)

test('silence has eight zero bands in both channels and the combined spectrum', function()
  for _, size in { 512, 1024, 2048 } do
    local hop = analyse(buffer.create(size * 8), size)
    for _, field in { 'spectrum', 'leftSpectrum', 'rightSpectrum' } do
      expect.equal(#hop[field], 8, 'silence retains all eight bands')
      for band = 1, 8 do
        expect.equal(hop[field][band], 0, 'silence has zero power')
      end
    end
    for _, field in
      { 'bassPower', 'midPower', 'treblePower', 'rms', 'peak', 'flux', 'onset', 'bassOnset', 'midOnset', 'trebleOnset' }
    do
      expect.equal(hop[field], 0, 'silence preserves zero ' .. field)
    end
  end
end)

test('retained channel spectra are frozen and survive later windows and batch reuse', function()
  local size = 512
  local analyser = features.new { size = size }
  local first = pcm(size, function(frame: number): (number, number)
    return tone(frame, size, 16, 0.5), 0
  end)
  local retained = analyser:feed(first, { frameCount = size, generation = 1, sequence = 1, startFrame = 0 }).hops[1]
  local copies = {}
  for _, field in { 'spectrum', 'leftSpectrum', 'rightSpectrum' } do
    expect.truthy(table.isfrozen(retained[field]), 'a retained spectrum is frozen')
    copies[field] = table.clone(retained[field])
    expect.raises(function()
      retained[field][6] = 1
    end, nil, 'a retained spectrum rejects mutation')
  end
  analyser:beginFrame()
  local second = pcm(size, function(frame: number): (number, number)
    return 0, tone(frame, size, 96, 0.25)
  end)
  local batch = analyser:feed(second, { frameCount = size, generation = 1, sequence = 2, startFrame = size })
  expect.truthy(batch.latest.rightSpectrum[8] > 0.03, 'later scratch values differ from retained spectra')
  for _, field in { 'spectrum', 'leftSpectrum', 'rightSpectrum' } do
    for band = 1, 8 do
      expect.equal(retained[field][band], copies[field][band], 'later analysis cannot mutate a retained band')
    end
  end
end)

return test
