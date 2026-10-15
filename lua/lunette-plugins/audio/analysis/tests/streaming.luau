local testing = require '@testing'
local expect = testing.expect
local features = require '../private/features'
local test = testing.suite()

type Config = features.Config
type Hop = features.Hop
type Metadata = features.Metadata

local function signal(count: number): buffer
  local samples = buffer.create(count * 8)
  for frame = 0, count - 1 do
    local amplitude = if frame % 3000 < 1300 then 0.02 else 0.5
    local left = amplitude * math.sin(2 * math.pi * 1125 * frame / 48000)
    local right = -left + 0.1 * math.sin(2 * math.pi * 4500 * frame / 48000)
    buffer.writef32(samples, frame * 8, left)
    buffer.writef32(samples, frame * 8 + 4, right)
  end
  return samples
end

local function block(samples: buffer, start: number, count: number): buffer
  local result = buffer.create(count * 8)
  buffer.copy(result, 0, samples, start * 8, count * 8)
  return result
end

local function collect(samples: buffer, config: Config, chunks: { number }, separateFrames: boolean): { Hop }
  local analyser = features.new(config)
  local result = {}
  local offset, sequence, packet = 0, 0, 1
  local batch = analyser:beginFrame()
  while offset < buffer.len(samples) / 8 do
    local count = math.min(chunks[packet % #chunks + 1], buffer.len(samples) / 8 - offset)
    packet += 1
    sequence += 1
    if separateFrames then
      batch = analyser:beginFrame()
    end
    local first = #batch.hops + 1
    local metadata: Metadata = {
      frameCount = count,
      generation = 7,
      sequence = sequence,
      startFrame = 10000 + offset,
    }
    analyser:feed(block(samples, offset, count), metadata)
    expect.falsy(batch.gap, 'contiguous packetization has no gap')
    for index = first, #batch.hops do
      table.insert(result, batch.hops[index])
    end
    offset += count
  end
  return result
end

test('analysis_is_packetization_invariant', function()
  local samples = signal(12000)
  for _, size in { 512, 1024, 2048 } do
    for _, hop in { size / 4, size / 2 } do
      local config = { size = size, hop = hop }
      local whole = collect(samples, config, { 12000 }, false)
      local fragmented = collect(samples, config, { 0, 1, 17, 511, 67, 2049, 3, 129 }, false)
      local rendered = collect(samples, config, { 31, 2000, 0, 1, 701, 50 }, true)
      local expectedCount = 1 + math.floor((12000 - size) / hop)
      expect.equal(#whole, expectedCount, 'complete sample-time hops')
      expect.equal(#fragmented, #whole, 'fragmented hop count')
      expect.equal(#rendered, #whole, 'render-frame-independent hop count')
      local onsets = 0
      for index, wanted in whole do
        expect.equal(wanted.generation, 7, 'the stream generation')
        expect.equal(wanted.endFrame, 10000 + size + (index - 1) * hop, 'the exclusive end frame')
        if wanted.onset > 0 then
          onsets += 1
        end
        for _, actual in { fragmented[index], rendered[index] } do
          for _, key in
            { 'generation', 'endFrame', 'bassPower', 'midPower', 'treblePower', 'rms', 'peak', 'flux', 'onset' }
          do
            expect.equal(actual[key], wanted[key], 'packetization-invariant ' .. key)
          end
          for _, key in { 'spectrum', 'leftSpectrum', 'rightSpectrum' } do
            for band = 1, 8 do
              expect.equal(actual[key][band], wanted[key][band], 'packetization-invariant ' .. key .. ' band ' .. band)
            end
          end
        end
      end
      expect.truthy(onsets >= 2, 'several onsets survive in one render frame')
    end
  end
end)

test('duplicate old sequences and generations are consumed at most once', function()
  local analyser = features.new { size = 512 }
  local samples = signal(512)
  local batch = analyser:feed(samples, { frameCount = 512, generation = 2, sequence = 4, startFrame = 0 })
  expect.equal(#batch.hops, 1, 'the original block')
  analyser:feed(samples, { frameCount = 512, generation = 2, sequence = 4, startFrame = 0, gap = true })
  analyser:feed(samples, { frameCount = 512, generation = 2, sequence = 3, startFrame = 0 })
  analyser:feed(samples, { frameCount = 512, generation = 1, sequence = 100, startFrame = 0 })
  expect.equal(#batch.hops, 1, 'repeated retained blocks do not duplicate hops')
  expect.equal(batch.acceptedFrames, 512, 'repeated blocks use no input budget')
  expect.falsy(batch.gap, 'repeated blocks do not reset history')
  analyser:beginFrame()
  batch = analyser:feed(buffer.create(0), { frameCount = 0, generation = 2, sequence = 5, startFrame = 512 })
  expect.equal(#batch.hops, 0, 'a zero-frame block emits nothing')
  expect.falsy(batch.gap, 'a zero-frame block preserves continuity')
end)

test('every discontinuity resets carried windows and onset history', function()
  for _, discontinuity in
    {
      { generation = 2, sequence = 2, startFrame = 384 },
      { generation = 1, sequence = 3, startFrame = 384 },
      { generation = 1, sequence = 2, startFrame = 500 },
      { generation = 1, sequence = 2, startFrame = 384, gap = true },
    }
  do
    local analyser = features.new { size = 512 }
    local samples = signal(1024)
    analyser:feed(block(samples, 0, 384), { frameCount = 384, generation = 1, sequence = 1, startFrame = 0 })
    analyser:beginFrame()
    local batch = analyser:feed(block(samples, 384, 128), {
      frameCount = 128,
      generation = discontinuity.generation,
      sequence = discontinuity.sequence,
      startFrame = discontinuity.startFrame,
      gap = discontinuity.gap,
    })
    expect.truthy(batch.gap, 'the discontinuity is explicit')
    expect.equal(#batch.hops, 0, 'old carry cannot complete a new window')
    analyser:feed(block(samples, 512, 384), {
      frameCount = 384,
      generation = discontinuity.generation,
      sequence = discontinuity.sequence + 1,
      startFrame = discontinuity.startFrame + 128,
    })
    expect.equal(#batch.hops, 1, 'a complete new window')
    expect.equal(batch.hops[1].flux, 0, 'the flux baseline resets')
    expect.equal(batch.hops[1].endFrame, discontinuity.startFrame + 512, 'new sample time')
    analyser:reset()
    analyser:beginFrame()
    batch = analyser:feed(block(samples, 0, 512), { frameCount = 512, generation = 0, sequence = 0, startFrame = 0 })
    expect.equal(#batch.hops, 1, 'reset accepts a fresh stream')
    expect.falsy(batch.gap, 'explicit reset has no implicit previous generation')
  end
end)

test('a gap after complete hops cannot create a false onset from the previous stream', function()
  local analyser = features.new { size = 512 }
  analyser:feed(signal(2048), { frameCount = 2048, generation = 1, sequence = 1, startFrame = 0 })
  analyser:beginFrame()
  local batch = analyser:feed(signal(512), {
    frameCount = 512,
    generation = 1,
    sequence = 2,
    startFrame = 2048,
    gap = true,
  })
  expect.truthy(batch.gap, 'the gap after complete output is explicit')
  expect.equal(#batch.hops, 1, 'the new stream needs a full window')
  expect.equal(batch.hops[1].flux, 0, 'the previous magnitudes are not a flux baseline')
  expect.equal(batch.hops[1].onset, 0, 'the gap cannot create an onset')
  expect.equal(batch.latest, batch.hops[1], 'a fresh complete window after a reset becomes current steady data')
end)

test('a warmed carry can produce 94 hops without growing the output capacity', function()
  local analyser = features.new { size = 512 }
  analyser:feed(signal(511), { frameCount = 511, generation = 1, sequence = 1, startFrame = 0 })
  analyser:beginFrame()
  local batch = analyser:feed(signal(12000), {
    frameCount = 12000,
    generation = 1,
    sequence = 2,
    startFrame = 511,
  })
  expect.equal(#batch.hops, 94, 'the maximum complete-hop batch')
  expect.equal(batch.hops[1].endFrame, 512, 'the carried first window')
  expect.equal(batch.hops[94].endFrame, 512 + 93 * 128, 'the final complete window')
  expect.falsy(batch.gap, 'the exact input budget remains valid')
end)

test('input budgets malformed PCM and invalid samples have bounded explicit outcomes', function()
  local analyser = features.new { size = 512 }
  local samples = signal(12000)
  local reusable = analyser:beginFrame()
  local batch = analyser:feed(samples, { frameCount = 12000, generation = 1, sequence = 1, startFrame = 0 })
  expect.equal(batch, reusable, 'the batch is reused')
  expect.truthy(#batch.hops <= 94, 'the output hop bound')
  expect.equal(batch.acceptedFrames, 12000, 'the input frame bound')
  local priorCount = #batch.hops
  analyser:feed(block(samples, 0, 1), { frameCount = 1, generation = 1, sequence = 2, startFrame = 12000 })
  expect.truthy(batch.gap, 'excess input produces a gap')
  expect.equal(batch.gapReason, 'capacity', 'the capacity reason')
  expect.equal(batch.droppedFrames, 1, 'the discarded frame count')
  expect.equal(#batch.hops, priorCount, 'existing output records remain available')
  expect.equal(batch.latest, nil, 'the capacity reset clears current steady history despite earlier output')
  expect.equal(analyser:beginFrame(), reusable, 'the next frame retains the batch allocation')
  expect.equal(#batch.hops, 0, 'the next frame clears its output')
  batch = analyser:feed(block(samples, 0, 128), { frameCount = 128, generation = 1, sequence = 3, startFrame = 12001 })
  expect.equal(#batch.hops, 0, 'the excess reset carry')
  local oversized = buffer.create(12001 * 8)
  analyser:beginFrame()
  batch = analyser:feed(oversized, { frameCount = 12001, generation = 1, sequence = 4, startFrame = 12129 })
  expect.equal(batch.droppedFrames, 12001, 'an oversized block is dropped without scanning')
  expect.equal(batch.acceptedFrames, 0, 'oversized input is not accepted')
  local invalid = signal(512)
  buffer.writef32(invalid, 0, 0 / 0)
  analyser:beginFrame()
  batch = analyser:feed(invalid, { frameCount = 512, generation = 1, sequence = 5, startFrame = 24130 })
  expect.equal(batch.gapReason, 'invalidSamples', 'non-finite PCM is explicit')
  expect.equal(#batch.hops, 0, 'invalid PCM produces no partial result')
  local badMetadata = {
    { frameCount = -1, generation = 1, sequence = 6, startFrame = 0 },
    { frameCount = 0, generation = 0 / 0, sequence = 6, startFrame = 0 },
    { frameCount = 0, generation = 1, sequence = 6.5, startFrame = 0 },
    { frameCount = 1, generation = 1, sequence = 6, startFrame = 9007199254740991 },
    { frameCount = 1, generation = 1, sequence = 6, startFrame = 0 },
  }
  for _, metadata in badMetadata do
    expect.raises(function()
      analyser:feed(buffer.create(0), metadata)
    end, 'audio analysis:')
  end
  for _, config in { { size = 256 }, { size = 512, hop = 64 }, { sampleRate = 44100 } } do
    expect.raises(function()
      features.new(config)
    end, 'audio analysis:')
  end
end)

return test
