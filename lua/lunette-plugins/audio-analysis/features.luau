-- Streaming stereo analysis at sample-time hops. No native API, render clock, or source-selection policy is used here.
-- feed accepts interleaved little-endian f32 stereo PCM. startFrame is zero-based; endFrame is exclusive.
-- beginFrame clears the reusable batch and its budgets. The batch remains valid until the next beginFrame call.
-- Generations increase monotonically. Sequences increase within a generation; retained older blocks have no effect.
-- A rejected block reports droppedFrames and a gap, and resets carry. A malformed buffer or metadata raises an error.

local fft = require './fft'

local features = {}
local isFinite: (number) -> boolean
local isInteger: (number) -> boolean

export type Config = {
  read size: number?,
  read hop: number?,
  read sampleRate: number?,
}

export type Metadata = {
  read frameCount: number,
  read generation: number,
  read sequence: number,
  read startFrame: number,
  read gap: boolean?,
}

export type Hop = {
  read generation: number,
  read endFrame: number,
  read rms: number,
  read peak: number,
  read bassPower: number,
  read midPower: number,
  read treblePower: number,
  read bass: number,
  read mid: number,
  read treble: number,
  read flux: number,
  read onset: number,
}

export type GapReason = 'generation' | 'discontinuity' | 'capacity' | 'invalidSamples'
export type Batch = {
  hops: { Hop },
  -- Last hop emitted in this batch after its most recent history reset.
  latest: Hop?,
  gap: boolean,
  gapReason: GapReason?,
  acceptedFrames: number,
  droppedFrames: number,
}

export type Analyzer = {
  read size: number,
  read hop: number,
  read sampleRate: number,
  read beginFrame: (Analyzer) -> Batch,
  read feed: (Analyzer, buffer, Metadata) -> Batch,
  read reset: (Analyzer) -> (),
}

-- Band Power fields integrate one-sided bin powers by bin centre; bass, mid, and treble are their square roots.
-- A batch accepts at most 12,000 frames and emits at most 94 hops, across all feed calls in that render frame.
function features.new(config: Config?): Analyzer
  local settings: Config = config or {}
  local size = settings.size or 2048
  local hop = settings.hop or size / 4
  local sampleRate = settings.sampleRate or 48000
  assert(size == 512 or size == 1024 or size == 2048, 'audio analysis: size must be 512, 1024, or 2048')
  assert(hop == size / 4 or hop == size / 2, 'audio analysis: hop must be a quarter or half of the size')
  assert(sampleRate == 48000, 'audio analysis: sample rate must be 48000')

  local transform = fft.new(size)
  local real = transform.real
  local imag = transform.imag
  local left: { number } = table.create(size, 0)
  local right: { number } = table.create(size, 0)
  local window: { number } = table.create(size, 0)
  local powers: { number } = table.create(size / 2 + 1, 0)
  local previous: { number } = table.create(size / 2 + 1, 0)
  local bands: { number } = table.create(size / 2 + 1, 0)
  local windowSquares = 0
  for index = 0, size - 1 do
    local value = 0.5 - 0.5 * math.cos(2 * math.pi * index / size)
    window[index + 1] = value
    windowSquares += value * value
  end
  for bin = 0, size / 2 do
    local frequency = bin * sampleRate / size
    if frequency >= 30 and frequency < 250 then
      bands[bin + 1] = 1
    elseif frequency >= 250 and frequency < 2000 then
      bands[bin + 1] = 2
    elseif frequency >= 2000 and frequency < 10000 then
      bands[bin + 1] = 3
    end
  end
  local normalisation = 1 / (size * windowSquares)
  local batch: Batch = {
    hops = table.create(94) :: { Hop },
    latest = nil,
    gap = false,
    gapReason = nil,
    acceptedFrames = 0,
    droppedFrames = 0,
  }
  local writeIndex = 1
  local filled = 0
  local untilHop = size
  local generation: number? = nil
  local sequence: number? = nil
  local nextFrame: number? = nil
  local hasPrevious = false
  local attemptedFrames = 0

  local function clearHistory(): ()
    writeIndex = 1
    filled = 0
    untilHop = size
    hasPrevious = false
    batch.latest = nil
  end

  local function markGap(reason: GapReason): ()
    batch.gap = true
    batch.gapReason = reason
    clearHistory()
  end

  local function analyse(currentGeneration: number, endFrame: number): Hop
    local squares = 0
    local peak = 0
    for index = 1, size do
      local l = left[index]
      local r = right[index]
      squares += l * l + r * r
      peak = math.max(peak, math.abs(l), math.abs(r))
    end
    local rms = math.sqrt(squares / (size * 2))
    for channel = 1, 2 do
      local carry = if channel == 1 then left else right
      for index = 1, size do
        local source = (writeIndex + index - 2) % size + 1
        real[index] = carry[source] * window[index]
        imag[index] = 0
      end
      transform:transform()
      for bin = 0, size / 2 do
        local index = bin + 1
        local power = (real[index] * real[index] + imag[index] * imag[index]) * normalisation
        if bin ~= 0 and bin ~= size / 2 then
          power *= 2
        end
        if channel == 1 then
          powers[index] = power / 2
        else
          powers[index] += power / 2
        end
      end
    end
    local bass = 0
    local mid = 0
    local treble = 0
    local increase = 0
    local previousSum = 0
    for index = 1, #powers do
      local band = bands[index]
      local power = powers[index]
      if band == 1 then
        bass += power
      elseif band == 2 then
        mid += power
      elseif band == 3 then
        treble += power
      end
      if band ~= 0 then
        local magnitude = math.sqrt(power)
        increase += math.max(0, magnitude - previous[index])
        previousSum += previous[index]
        previous[index] = magnitude
      end
    end
    local flux = 0
    -- The first complete window establishes a baseline, including after a discontinuity.
    if hasPrevious and rms >= 0.001 then
      flux = math.clamp(increase / math.max(previousSum, 0.001), 0, 1)
    end
    hasPrevious = true
    return {
      generation = currentGeneration,
      endFrame = endFrame,
      rms = rms,
      peak = peak,
      bassPower = bass,
      midPower = mid,
      treblePower = treble,
      bass = math.sqrt(bass),
      mid = math.sqrt(mid),
      treble = math.sqrt(treble),
      flux = flux,
      onset = math.clamp((flux - 0.08) / 0.24, 0, 1),
    }
  end

  return table.freeze {
    size = size,
    hop = hop,
    sampleRate = sampleRate,
    beginFrame = function(_self: Analyzer): Batch
      table.clear(batch.hops)
      batch.latest = nil
      batch.gap = false
      batch.gapReason = nil
      batch.acceptedFrames = 0
      batch.droppedFrames = 0
      attemptedFrames = 0
      return batch
    end,
    reset = function(_self: Analyzer): ()
      clearHistory()
      generation = nil
      sequence = nil
      nextFrame = nil
    end,
    feed = function(_self: Analyzer, pcm: buffer, metadata: Metadata): Batch
      local frameCount = metadata.frameCount
      local currentGeneration = metadata.generation
      local currentSequence = metadata.sequence
      local startFrame = metadata.startFrame
      assert(isInteger(frameCount) and isInteger(startFrame), 'audio analysis: invalid frame position or count')
      assert(
        isInteger(currentGeneration) and isInteger(currentSequence),
        'audio analysis: invalid generation or sequence'
      )
      assert(isInteger(startFrame + frameCount), 'audio analysis: frame position exceeds exact integer range')
      assert(buffer.len(pcm) == frameCount * 8, 'audio analysis: PCM length must match stereo frame count')

      if generation ~= nil and currentGeneration < generation then
        return batch
      end
      if generation == currentGeneration and sequence ~= nil and currentSequence <= sequence then
        return batch
      end
      if generation ~= nil and generation ~= currentGeneration then
        markGap 'generation'
      elseif
        metadata.gap
        or (nextFrame ~= nil and startFrame ~= nextFrame)
        or (sequence ~= nil and currentSequence ~= sequence + 1)
      then
        markGap 'discontinuity'
      end
      generation = currentGeneration
      sequence = currentSequence
      nextFrame = startFrame + frameCount

      local hopCount = if frameCount < untilHop then 0 else 1 + math.floor((frameCount - untilHop) / hop)
      if attemptedFrames + frameCount > 12000 or #batch.hops + hopCount > 94 then
        attemptedFrames = 12000
        batch.droppedFrames += frameCount
        markGap 'capacity'
        return batch
      end
      attemptedFrames += frameCount
      -- Validation precedes carry mutation so a non-finite block cannot contaminate later windows.
      for frame = 0, frameCount - 1 do
        local l = buffer.readf32(pcm, frame * 8)
        local r = buffer.readf32(pcm, frame * 8 + 4)
        if not isFinite(l) or not isFinite(r) then
          batch.droppedFrames += frameCount
          markGap 'invalidSamples'
          return batch
        end
      end
      batch.acceptedFrames += frameCount
      for frame = 0, frameCount - 1 do
        left[writeIndex] = buffer.readf32(pcm, frame * 8)
        right[writeIndex] = buffer.readf32(pcm, frame * 8 + 4)
        writeIndex = writeIndex % size + 1
        filled = math.min(filled + 1, size)
        untilHop -= 1
        if filled == size and untilHop == 0 then
          local record = analyse(currentGeneration, startFrame + frame + 1)
          table.insert(batch.hops, record)
          batch.latest = record
          untilHop = hop
        end
      end
      return batch
    end,
  }
end

isFinite = function(value: number): boolean
  return value == value and math.abs(value) < math.huge
end

isInteger = function(value: number): boolean
  return isFinite(value) and value >= 0 and value <= 9007199254740991 and value % 1 == 0
end

return features
