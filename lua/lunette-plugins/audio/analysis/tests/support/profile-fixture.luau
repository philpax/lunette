local testing = require '@testing'
local fft = require '../../private/fft'
local features = require '../../private/features'
local contract = require '@lunette-contracts/audio-analysis'

local fixture = {}

export type Counts = {
  fftNew: number,
  transforms: number,
  analyzerNew: number,
  beginFrames: number,
  feeds: number,
}
export type Failures = { feed: boolean }
export type Observed = testing.Observed<contract.Service> & {
  service: contract.Service,
  context: testing.Context,
}
export type Fixture = {
  session: testing.Session & { native: testing.Native },
  observed: Observed,
  counts: Counts,
  failures: Failures,
  restore: () -> (),
  advance: () -> (),
}

-- Instrument real pure modules only for this test. Production code exposes no counters or inspection methods.
function fixture.new(): Fixture
  local counts = { fftNew = 0, transforms = 0, analyzerNew = 0, beginFrames = 0, feeds = 0 }
  local failures = { feed = false }
  local newFft, newAnalyzer = fft.new, features.new
  fft.new = function(size: number): fft.Transform
    counts.fftNew += 1
    local real = newFft(size)
    return {
      size = real.size,
      real = real.real,
      imag = real.imag,
      transform = function(_self: fft.Transform): ()
        counts.transforms += 1
        real:transform()
      end,
    }
  end
  features.new = function(config: features.Config?): features.Analyzer
    counts.analyzerNew += 1
    local real = newAnalyzer(config)
    return {
      size = real.size,
      hop = real.hop,
      sampleRate = real.sampleRate,
      beginFrame = function(_self: features.Analyzer): features.Batch
        counts.beginFrames += 1
        return real:beginFrame()
      end,
      feed = function(_self: features.Analyzer, pcm: buffer, metadata: features.Metadata): features.Batch
        counts.feeds += 1
        if failures.feed then
          error 'fixture unexpected feed error'
        end
        return real:feed(pcm, metadata)
      end,
      reset = function(_self: features.Analyzer): ()
        real:reset()
      end,
    }
  end
  local session = testing.boot { 'frame', 'audio', 'audio-analysis' }
  local native = session.native :: testing.Native
  local observed = session:observe(contract.capability) :: Observed
  local restored = false
  local function restore()
    if not restored then
      restored = true
      fft.new, features.new = newFft, newAnalyzer
    end
  end
  observed.context:effect(function(): () -> ()
    return restore
  end)
  return {
    session = session,
    observed = observed,
    counts = counts,
    failures = failures,
    restore = restore,
    advance = function(): ()
      native.advanceFrame()
      session:update()
    end,
  }
end

function fixture.signal(count: number, offset: number?, level: number?): buffer
  local pcm = buffer.create(count * 8)
  for frame = 0, count - 1 do
    local sample = (level or 0.5) * math.sin(2 * math.pi * 1500 * (frame + (offset or 0)) / 48000)
    buffer.writef32(pcm, frame * 8, sample)
    buffer.writef32(pcm, frame * 8 + 4, -sample)
  end
  return pcm
end

function fixture.open(observed: Observed, source: contract.Source, options: contract.Options?): contract.Reader
  local result = observed.service:open(observed.context, source, options)
  testing.expect.equal(result.kind, 'success', result.detail)
  return result.reader
end

return fixture
