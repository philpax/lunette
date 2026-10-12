-- Feature-domain response envelopes. Source changes preserve the displayed response and never mix PCM.
-- The caller consumes every completed hop, then steps once per render frame. Values remain valid until the next step.

local envelope = {}
local finite: (number) -> boolean
local unit: (number) -> number
local smooth: (number, number, number, number, number) -> number

export type Config = {
  read attack: number?,
  read release: number?,
  read onsetRelease: number?,
  read crossfade: number?,
  read loss: number?,
}

export type Feature = {
  read bass: number,
  read mid: number,
  read treble: number,
  read rms: number,
  read peak: number,
  read onset: number,
}

export type Values = {
  bass: number,
  mid: number,
  treble: number,
  rms: number,
  peak: number,
  onset: number,
  waves: number,
}

export type Response = {
  read values: Values,
  read switchSource: (Response, string?) -> (),
  read consume: (Response, Feature) -> (),
  read step: (Response, number) -> Values,
}

function envelope.new(config: Config?): Response
  local settings: Config = config or {}
  local attack = settings.attack or 0.06
  local release = settings.release or 0.45
  local onsetRelease = settings.onsetRelease or release
  local crossfade = settings.crossfade or 1.2
  local loss = settings.loss or 1.5
  for _, seconds in { attack, release, onsetRelease, crossfade, loss } do
    assert(finite(seconds) and seconds > 0, 'audio envelope: times must be finite and positive')
  end
  local values: Values = { bass = 0, mid = 0, treble = 0, rms = 0, peak = 0, onset = 0, waves = 0 }
  local from: Values = { bass = 0, mid = 0, treble = 0, rms = 0, peak = 0, onset = 0, waves = 0 }
  local targetBass, targetMid, targetTreble, targetRms, targetPeak = 0, 0, 0, 0, 0
  local bass = 0
  local mid = 0
  local treble = 0
  local rms = 0
  local peak = 0
  local waves = 0
  local pendingOnset = 0
  local source: string? = nil
  local elapsed = 0
  local duration = loss

  return table.freeze {
    values = values,
    switchSource = function(_self: Response, nextSource: string?): ()
      if nextSource == source then
        return
      end
      source = nextSource
      from.bass, from.mid, from.treble = values.bass, values.mid, values.treble
      from.rms, from.peak = values.rms, values.peak
      from.onset, from.waves = values.onset, values.waves
      bass, mid, treble, rms, peak, waves = 0, 0, 0, 0, 0, 0
      targetBass, targetMid, targetTreble, targetRms, targetPeak = 0, 0, 0, 0, 0
      pendingOnset = 0
      elapsed = 0
      duration = if source == nil then loss else crossfade
    end,
    consume = function(_self: Response, feature: Feature): ()
      if source == nil then
        return
      end
      -- Non-finite features become zero at the response boundary; PCM validation belongs to analysis.
      targetBass, targetMid, targetTreble = unit(feature.bass), unit(feature.mid), unit(feature.treble)
      targetRms, targetPeak = unit(feature.rms), unit(feature.peak)
      pendingOnset = math.max(pendingOnset, unit(feature.onset))
    end,
    step = function(_self: Response, dt: number): Values
      if not finite(dt) or dt <= 0 then
        return values
      end
      elapsed = math.min(duration, elapsed + dt)
      local mix = elapsed / duration
      if source ~= nil then
        bass = smooth(bass, targetBass, dt, attack, release)
        mid = smooth(mid, targetMid, dt, attack, release)
        treble = smooth(treble, targetTreble, dt, attack, release)
        rms = smooth(rms, targetRms, dt, attack, release)
        peak = smooth(peak, targetPeak, dt, attack, release)
        waves = math.max(pendingOnset, waves * math.exp(-dt / onsetRelease))
      end
      values.bass = from.bass * (1 - mix) + bass * mix
      values.mid = from.mid * (1 - mix) + mid * mix
      values.treble = from.treble * (1 - mix) + treble * mix
      values.rms = from.rms * (1 - mix) + rms * mix
      values.peak = from.peak * (1 - mix) + peak * mix
      values.onset = from.onset * (1 - mix) + pendingOnset * mix
      values.waves = from.waves * (1 - mix) + waves * mix
      pendingOnset = 0
      return values
    end,
  }
end

finite = function(value: number): boolean
  return value == value and math.abs(value) < math.huge
end

unit = function(value: number): number
  return if finite(value) then math.clamp(value, 0, 1) else 0
end

smooth = function(value: number, target: number, dt: number, attack: number, release: number): number
  local seconds = if target > value then attack else release
  return target + (value - target) * math.exp(-dt / seconds)
end

return envelope
