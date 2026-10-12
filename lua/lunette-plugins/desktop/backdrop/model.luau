-- Pure visibility, autonomous motion, and bounded response to normalized audio features.
local config = require './config'

local model = {}

export type Features = { read bass: number, read mid: number, read treble: number }
export type Onset = { read strength: number, read position: number?, read age: number? }
export type FeatureOptions = { read gap: ('publication' | 'capacity')?, read discardedHops: number? }
export type Wave = { age: number, strength: number, position: number }
export type Frame = {
  read visibility: number,
  read time: number,
  read bass: number,
  read mid: number,
  read treble: number,
  read brightness: number,
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
  response: Features,
  target: Features,
  responseStrength: number,
  motionStrength: number,
  transitionFrom: Features,
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
local ZERO: Features = table.freeze { bass = 0, mid = 0, treble = 0 }
local WAVE_LIFETIME = 3
local MAX_WAVES = 8
local finite: (number) -> boolean
local unit: (number) -> number
local mix: (Features, Features, number) -> Features
local envelope: (number, number, number, config.Settings) -> number

function model.new(settings: config.Settings): State
  return setmetatable({
    settings = settings,
    enabled = settings.enabled,
    visibility = 0,
    time = 0,
    response = ZERO,
    target = ZERO,
    responseStrength = settings.response,
    motionStrength = settings.motion,
    transitionFrom = ZERO,
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
  self.target = { bass = unit(features.bass), mid = unit(features.mid), treble = unit(features.treble) }
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
  if #onsets > MAX_WAVES then
    self.onsetGap = 'capacity'
    self.discardedHops = math.min(self.discardedHops + #onsets - MAX_WAVES, 9007199254740991)
    table.clear(self.waves)
  end
  for index = math.max(1, #onsets - MAX_WAVES + 1), #onsets do
    local onset = onsets[index]
    local strength, givenAge = unit(onset.strength), onset.age or 0
    local age = if finite(givenAge) then math.max(0, givenAge) else WAVE_LIFETIME
    if strength > 0 and age < WAVE_LIFETIME then
      if #self.waves == MAX_WAVES then
        table.remove(self.waves, 1)
        self.onsetGap = 'capacity'
        self.discardedHops = math.min(self.discardedHops + 1, 9007199254740991)
      end
      table.insert(self.waves, { age = age, strength = strength, position = unit(onset.position or 0) })
    end
  end
end

-- Standalone clients can request a source transition; the response child mixes its two sources before delivery.
function State.sourceChanged(self: State): ()
  self.transitionFrom = self.response
  self.transitionAge = 0
  self.target = ZERO
  self.transitioning, self.settling = true, false
end

-- Repeated unavailable samples must not restart the settling interval.
function State.noAudio(self: State): ()
  if self.settling then
    return
  end
  self.transitionFrom = self.response
  self.transitionAge = 0
  self.target = ZERO
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
    self.response = {
      bass = envelope(self.response.bass, self.target.bass, elapsed, self.settings),
      mid = envelope(self.response.mid, self.target.mid, elapsed, self.settings),
      treble = envelope(self.response.treble, self.target.treble, elapsed, self.settings),
    }
  end
  for index = #self.waves, 1, -1 do
    local wave = self.waves[index]
    wave.age = math.min(wave.age + elapsed, WAVE_LIFETIME)
    if wave.age >= WAVE_LIFETIME then
      table.remove(self.waves, index)
    end
  end
  local response = self.responseStrength
  return {
    visibility = self.visibility,
    time = self.time,
    bass = self.response.bass * response,
    mid = self.response.mid * response,
    treble = self.response.treble * response,
    brightness = math.clamp(self.settings.brightness * (0.85 + 0.15 * self.response.bass * response), 0, 1),
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

mix = function(a: Features, b: Features, amount: number): Features
  return {
    bass = a.bass + (b.bass - a.bass) * amount,
    mid = a.mid + (b.mid - a.mid) * amount,
    treble = a.treble + (b.treble - a.treble) * amount,
  }
end

envelope = function(current: number, target: number, dt: number, settings: config.Settings): number
  local duration = if target > current then settings.attackDuration else settings.releaseDuration
  local amount = if duration == 0 then 1 else 1 - math.exp(-math.min(dt, 60) / duration)
  return current + (target - current) * amount
end

return model
