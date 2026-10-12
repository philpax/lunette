-- Pure visibility, autonomous motion, and bounded response to normalized audio features.
-- Each coarse band has its own onset action: bass heaves the curtains, mid sends a travelling ripple, and
-- treble scatters glints. Waves are pooled per band so frequent treble onsets cannot evict a bass heave.
local config = require './config'

local model = {}

export type Band = 'bass' | 'mid' | 'treble'
-- Spectrum holds eight normalized bands from low to high. Without it, each coarse band fills its own bands.
export type Features = {
  read bass: number,
  read mid: number,
  read treble: number,
  read spectrum: { read [number]: number }?,
}
-- An onset without a band is a mid ripple.
export type Onset = { read strength: number, read position: number?, read age: number?, read band: Band? }
export type FeatureOptions = { read gap: ('publication' | 'capacity')?, read discardedHops: number? }
export type Wave = { age: number, strength: number, position: number, band: Band, lifetime: number }
type Response = { bass: number, mid: number, treble: number, spectrum: { number } }
export type Frame = {
  read visibility: number,
  read time: number,
  read bass: number,
  read mid: number,
  read treble: number,
  read brightness: number,
  read spectrum: { read [number]: number },
  read responseStrength: number,
  read onsetGap: ('publication' | 'capacity')?,
  read discardedHops: number,
  read waves: { Wave },
}
export type State = {
  settings: config.Settings,
  enabled: boolean,
  visibility: number,
  time: number,
  response: Response,
  target: Response,
  responseStrength: number,
  motionStrength: number,
  transitionFrom: Response,
  transitionAge: number,
  transitioning: boolean,
  settling: boolean,
  onsetGap: ('publication' | 'capacity')?,
  discardedHops: number,
  waves: { Wave },
  read setEnabled: (State, boolean) -> (),
  read setStrengths: (State, number, number) -> (),
  read setFeatures: (State, Features, { Onset }?, FeatureOptions?) -> (),
  read sourceChanged: (State) -> (),
  read noAudio: (State) -> (),
  read update: (State, number, boolean) -> Frame,
}

local State = {}
State.__index = State
model.SPECTRUM_BANDS = 8
-- The coarse band of each spectrum band, matching the analysis edges at 250 and 2000 Hz.
local COARSE: { Band } = table.freeze({ 'bass', 'bass', 'bass', 'mid', 'mid', 'mid', 'treble', 'treble' } :: { Band })
model.waveLifetimes = table.freeze { bass = 1.6, mid = 3, treble = 0.9 } :: { read [Band]: number }
model.wavePools = table.freeze { bass = 4, mid = 8, treble = 8 } :: { read [Band]: number }
model.MAX_WAVES = model.wavePools.bass + model.wavePools.mid + model.wavePools.treble
local finite: (number) -> boolean
local unit: (number) -> number
local zero: () -> Response
local normalized: (Features) -> Response
local mix: (Response, Response, number) -> Response
local envelope: (number, number, number, config.Settings) -> number
local countBand: ({ Wave }, Band) -> number
local removeOldest: ({ Wave }, Band) -> ()

function model.new(settings: config.Settings): State
  return setmetatable({
    settings = settings,
    enabled = settings.enabled,
    visibility = 0,
    time = 0,
    response = zero(),
    target = zero(),
    responseStrength = settings.response,
    motionStrength = settings.motion,
    transitionFrom = zero(),
    transitionAge = 0,
    transitioning = false,
    settling = true,
    onsetGap = nil :: ('publication' | 'capacity')?,
    discardedHops = 0,
    waves = {},
  }, State)
end

function State.setEnabled(self: State, enabled: boolean): ()
  self.enabled = enabled
end

function State.setStrengths(self: State, response: number, motion: number): ()
  self.responseStrength, self.motionStrength = unit(response), unit(motion)
end

-- Ages are relative to cumulative PCM publication sample time, not the render delta that delivers the hop.
function State.setFeatures(self: State, features: Features, onsets: { Onset }?, options: FeatureOptions?): ()
  self.target = normalized(features)
  if self.settling then
    self.transitioning = false
  end
  self.settling = false
  self.onsetGap = if options then options.gap else nil
  if options and options.gap then
    table.clear(self.waves)
  end
  local discarded = if options then options.discardedHops or 0 else 0
  if finite(discarded) and discarded > 0 then
    self.discardedHops = math.min(self.discardedHops + math.floor(discarded), 9007199254740991)
  end
  if not onsets then
    return
  end
  -- Only the newest pool-sized run of each band can survive this publication.
  local remaining: { [Band]: number } = { bass = 0, mid = 0, treble = 0 }
  for _, onset in onsets do
    local band: Band = onset.band or 'mid'
    remaining[band] += 1
  end
  for band, count in remaining do
    if count > model.wavePools[band] then
      self.onsetGap = 'capacity'
      self.discardedHops = math.min(self.discardedHops + count - model.wavePools[band], 9007199254740991)
      for index = #self.waves, 1, -1 do
        if self.waves[index].band == band then
          table.remove(self.waves, index)
        end
      end
    end
  end
  for _, onset in onsets do
    local band: Band = onset.band or 'mid'
    remaining[band] -= 1
    local lifetime = model.waveLifetimes[band]
    local strength, givenAge = unit(onset.strength), onset.age or 0
    local age = if finite(givenAge) then math.max(0, givenAge) else lifetime
    if remaining[band] < model.wavePools[band] and strength > 0 and age < lifetime then
      if countBand(self.waves, band) == model.wavePools[band] then
        removeOldest(self.waves, band)
        self.onsetGap = 'capacity'
        self.discardedHops = math.min(self.discardedHops + 1, 9007199254740991)
      end
      table.insert(self.waves, {
        age = age,
        strength = strength,
        position = unit(onset.position or 0),
        band = band,
        lifetime = lifetime,
      })
    end
  end
end

-- Standalone clients can request a source transition; the response child mixes its two sources before delivery.
function State.sourceChanged(self: State): ()
  self.transitionFrom = self.response
  self.transitionAge = 0
  self.target = zero()
  self.transitioning, self.settling = true, false
end

-- Repeated unavailable samples must not restart the settling interval.
function State.noAudio(self: State): ()
  if self.settling then
    return
  end
  self.transitionFrom = self.response
  self.transitionAge = 0
  self.target = zero()
  self.transitioning, self.settling = true, true
end

function State.update(self: State, dt: number, mainSessionVisible: boolean): Frame
  local elapsed = if finite(dt) and dt > 0 then dt else 0
  local duration = self.settings.fadeDuration
  local target = if self.enabled and not mainSessionVisible then 1 else 0
  local step = if duration == 0 then 1 else math.min(elapsed / duration, 1)
  self.visibility += math.clamp(target - self.visibility, -step, step)
  -- The period is shared by every autonomous shader frequency, keeping long sessions finite without a seam.
  self.time = (self.time + (elapsed % 4096) * self.motionStrength) % 4096
  if self.transitioning then
    local transitionDuration = if self.settling then self.settings.recoveryDuration else self.settings.crossfadeDuration
    self.transitionAge = math.min(self.transitionAge + elapsed, transitionDuration)
    local amount = if transitionDuration == 0 then 1 else self.transitionAge / transitionDuration
    self.response = mix(self.transitionFrom, self.target, amount)
    if amount == 1 then
      self.transitioning = false
    end
  elseif elapsed > 0 then
    local current, goal = self.response, self.target
    local spectrum = table.create(model.SPECTRUM_BANDS, 0)
    for band = 1, model.SPECTRUM_BANDS do
      spectrum[band] = envelope(current.spectrum[band], goal.spectrum[band], elapsed, self.settings)
    end
    self.response = {
      bass = envelope(current.bass, goal.bass, elapsed, self.settings),
      mid = envelope(current.mid, goal.mid, elapsed, self.settings),
      treble = envelope(current.treble, goal.treble, elapsed, self.settings),
      spectrum = spectrum,
    }
  end
  for index = #self.waves, 1, -1 do
    local wave = self.waves[index]
    wave.age = math.min(wave.age + elapsed, wave.lifetime)
    if wave.age >= wave.lifetime then
      table.remove(self.waves, index)
    end
  end
  local response = self.responseStrength
  local spectrum = table.create(model.SPECTRUM_BANDS, 0)
  for band = 1, model.SPECTRUM_BANDS do
    spectrum[band] = self.response.spectrum[band] * response
  end
  return {
    visibility = self.visibility,
    time = self.time,
    bass = self.response.bass * response,
    mid = self.response.mid * response,
    treble = self.response.treble * response,
    brightness = math.clamp(self.settings.brightness * (0.85 + 0.15 * self.response.bass * response), 0, 1),
    spectrum = spectrum,
    responseStrength = response,
    onsetGap = self.onsetGap,
    discardedHops = self.discardedHops,
    waves = self.waves,
  }
end

finite = function(value: number): boolean
  return value == value and math.abs(value) < math.huge
end

unit = function(value: number): number
  return if finite(value) then math.clamp(value, 0, 1) else 0
end

zero = function(): Response
  return { bass = 0, mid = 0, treble = 0, spectrum = table.create(model.SPECTRUM_BANDS, 0) }
end

normalized = function(features: Features): Response
  local result: Response = {
    bass = unit(features.bass),
    mid = unit(features.mid),
    treble = unit(features.treble),
    spectrum = table.create(model.SPECTRUM_BANDS, 0),
  }
  local given = features.spectrum
  for band = 1, model.SPECTRUM_BANDS do
    local value = if given then given[band] else nil
    local coarse = COARSE[band]
    local fallback = if coarse == 'bass' then result.bass elseif coarse == 'mid' then result.mid else result.treble
    result.spectrum[band] = if value ~= nil then unit(value) else fallback
  end
  return result
end

mix = function(a: Response, b: Response, amount: number): Response
  local spectrum = table.create(model.SPECTRUM_BANDS, 0)
  for band = 1, model.SPECTRUM_BANDS do
    spectrum[band] = a.spectrum[band] + (b.spectrum[band] - a.spectrum[band]) * amount
  end
  return {
    bass = a.bass + (b.bass - a.bass) * amount,
    mid = a.mid + (b.mid - a.mid) * amount,
    treble = a.treble + (b.treble - a.treble) * amount,
    spectrum = spectrum,
  }
end

envelope = function(current: number, target: number, dt: number, settings: config.Settings): number
  local duration = if target > current then settings.attackDuration else settings.releaseDuration
  local amount = if duration == 0 then 1 else 1 - math.exp(-math.min(dt, 60) / duration)
  return current + (target - current) * amount
end

countBand = function(waves: { Wave }, band: Band): number
  local count = 0
  for _, wave in waves do
    if wave.band == band then
      count += 1
    end
  end
  return count
end

removeOldest = function(waves: { Wave }, band: Band): ()
  for index, wave in waves do
    if wave.band == band then
      table.remove(waves, index)
      return
    end
  end
end

return model
