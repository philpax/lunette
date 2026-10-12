-- The optional analysis consumer owns at most two readers; source policy and panel direction are supplied data.
local plugin = require '@lunette-plugin'
local analysis = require '@lunette-contracts/audio-analysis'
local frame = require '@lunette-contracts/frame'
local config = require './config'
local model = require './model'
local selection = require './selection'

local responseChild = {}
type Slot = {
  reader: analysis.Reader,
  source: analysis.Source,
  generation: number?,
  endFrame: number?,
  publication: number?,
}
local ZERO: model.Features = table.freeze {
  bass = 0,
  mid = 0,
  treble = 0,
  spectrum = table.freeze(table.create(model.SPECTRUM_BANDS, 0)),
}
local BANDS: { model.Band } = table.freeze({ 'bass', 'mid', 'treble' } :: { model.Band })
-- Narrow bands hold less power than the coarse bands, and recorded music falls off with frequency, so the
-- fixed spectrum calibration rises from the coarse gain scaled for one octave to a treble lift.
local SPECTRUM_GAINS = table.freeze { 7, 7, 7, 7, 8, 10, 12, 14 }
local same: (analysis.Source?, analysis.Source?) -> boolean
local mapped: (analysis.Steady) -> model.Features
local power: (number, number) -> number
local mixed: (model.Features, model.Features, number) -> model.Features
local newest: (analysis.Snapshot) -> number?
local bandOnset: (analysis.Hop, model.Band) -> number
local removeOldest: ({ model.Onset }, model.Band) -> ()
local scatter: (number, number) -> number

-- Direction is normalized longitude. An optional panels child supplies it; analysis never requires panels or UI.
function responseChild.new(
  choice: selection.State,
  state: model.State,
  settings: config.Settings,
  needed: () -> boolean,
  direction: (() -> number?)?
): plugin.Definition<{}>
  return plugin.consumer<<{}, {}>>({
    name = 'desktop/backdrop/response',
    requires = { analysis.capability, frame.capability },
    init = function(context: plugin.Context, _settings: {}): ()
      local service: analysis.Service = context:require(analysis.capability)
      local frames: frame.Service = context:require(frame.capability)
      local current: Slot? = nil
      local previous: Slot? = nil
      local wantedBefore: analysis.Source? = nil
      local fadeAge = settings.crossfadeDuration
      local from: model.Features = ZERO
      local last: model.Features = ZERO
      local readOutgoing = false
      -- Longitude 0.5 faces -z, LÖVR's forward, until a panel offers a direction.
      local longitude = 0.5
      local directed = false
      local function close(slot: Slot?): ()
        if slot then
          slot.reader:close()
        end
      end
      local function release(): ()
        local old, active = previous, current
        previous, current, wantedBefore = nil, nil, nil
        close(old)
        close(active)
      end
      local function open(source: analysis.Source): Slot?
        local result = service:open(context, source)
        if result.kind ~= 'success' then
          choice.audioState = {
            kind = 'unavailable',
            reason = 'capacity-exceeded',
            detail = result.detail,
          }
          return nil
        end
        local publication = result.reader:snapshot()
        return {
          reader = result.reader,
          source = source,
          generation = publication.generation,
          endFrame = newest(publication),
          publication = publication.frameGeneration,
        }
      end
      context:effect(function(): () -> ()
        choice.audioAvailable = true
        return function(): ()
          release()
          choice.audioAvailable, choice.audioState = false, nil
          state:noAudio()
        end
      end)
      frames:onUpdate(context, {
        phase = 'scene',
        order = 100,
        run = function(dt: number): ()
          local elapsed = if dt == dt and dt > 0 and dt < math.huge then dt else 0
          if not needed() then
            release()
            state:noAudio()
            return
          end
          local wanted = choice:source()
          if not same(wantedBefore, wanted) then
            readOutgoing = fadeAge >= settings.crossfadeDuration
            close(previous)
            previous, current = current, nil
            wantedBefore = wanted
            fadeAge, from = 0, last
            if wanted then
              current = open(wanted)
            end
          elseif wanted and not current then
            current = open(wanted)
          end
          fadeAge = math.min(fadeAge + elapsed, settings.crossfadeDuration)
          local amount = if settings.crossfadeDuration == 0 then 1 else fadeAge / settings.crossfadeDuration
          if amount == 1 then
            close(previous)
            previous = nil
          end
          local offered = if direction then direction() else nil
          if offered and offered == offered and math.abs(offered) < math.huge then
            local destination = math.clamp(offered, 0, 1)
            local delta = (destination - longitude + 0.5) % 1 - 0.5
            local follow = if directed then 1 - math.exp(-math.min(elapsed, 60) / 0.25) else 1
            longitude = (longitude + delta * follow) % 1
            directed = true
          end
          local slot = current
          local snapshot = if slot then slot.reader:snapshot() else nil
          choice.audioState = if snapshot then snapshot.state elseif wanted then choice.audioState else nil
          local active = snapshot ~= nil and snapshot.state.kind == 'active'
          local target = if active and snapshot and snapshot.latest then mapped(snapshot.latest) else ZERO
          local outgoing = previous
          if outgoing and readOutgoing then
            local old = outgoing.reader:snapshot()
            from = if old.state.kind == 'active' and old.latest then mapped(old.latest) else ZERO
          end
          last = mixed(from, target, amount)
          if not active and amount == 1 then
            state:noAudio()
            return
          end
          local onsets: { model.Onset } = {}
          local counts: { [model.Band]: number } = { bass = 0, mid = 0, treble = 0 }
          local discarded = 0
          local gap: ('publication' | 'capacity')? = nil
          if active and slot and snapshot and slot.publication ~= snapshot.frameGeneration then
            gap = if snapshot.gap then 'publication' else nil
            slot.publication = snapshot.frameGeneration
            if slot.generation ~= snapshot.generation then
              gap = 'publication'
              slot.generation, slot.endFrame = snapshot.generation, nil
            end
            local publicationEnd = snapshot.endFrame
            for _, hop in snapshot.hops do
              if hop.generation == snapshot.generation and (slot.endFrame == nil or hop.endFrame > slot.endFrame) then
                slot.endFrame = hop.endFrame
                local age = if publicationEnd then math.max(0, publicationEnd - hop.endFrame) / 48000 else 0
                local weight = if settings.crossfadeDuration == 0
                  then 1
                  else math.clamp((fadeAge - age) / settings.crossfadeDuration, 0, 1)
                for _, band in BANDS do
                  local strength = bandOnset(hop, band)
                  if strength > 0 then
                    if counts[band] == model.wavePools[band] then
                      removeOldest(onsets, band)
                      discarded += 1
                      gap = 'capacity'
                    else
                      counts[band] += 1
                    end
                    onsets[#onsets + 1] = {
                      strength = strength * weight,
                      position = if band == 'treble' then scatter(longitude, hop.endFrame) else longitude,
                      age = age,
                      band = band,
                    }
                  end
                end
              end
            end
          end
          state:setFeatures(last, onsets, { gap = gap, discardedHops = discarded })
        end,
      })
    end,
  }).definition
end

same = function(a: analysis.Source?, b: analysis.Source?): boolean
  if a == nil or b == nil then
    return a == b
  elseif a.kind == 'system' then
    return b.kind == 'system'
  end
  return b.kind == 'process' and a.process.id == b.process.id
end

mapped = function(steady: analysis.Steady): model.Features
  local spectrum = table.create(model.SPECTRUM_BANDS, 0)
  for band = 1, model.SPECTRUM_BANDS do
    spectrum[band] = power(steady.spectrum[band] or 0, SPECTRUM_GAINS[band])
  end
  return {
    bass = power(steady.bassPower, 4),
    mid = power(steady.midPower, 4),
    treble = power(steady.treblePower, 4),
    spectrum = spectrum,
  }
end

-- Fixed full-scale calibration preserves silence and absolute strength; no per-frame peak normalization is used.
power = function(value: number, gain: number): number
  if value ~= value or math.abs(value) == math.huge or value <= 0 then
    return 0
  end
  return math.clamp(math.sqrt(value) * gain, 0, 1)
end

mixed = function(a: model.Features, b: model.Features, amount: number): model.Features
  local spectrum = table.create(model.SPECTRUM_BANDS, 0)
  local from, to = a.spectrum, b.spectrum
  for band = 1, model.SPECTRUM_BANDS do
    local start = if from then from[band] else 0
    local finish = if to then to[band] else 0
    spectrum[band] = start + (finish - start) * amount
  end
  return {
    bass = a.bass + (b.bass - a.bass) * amount,
    mid = a.mid + (b.mid - a.mid) * amount,
    treble = a.treble + (b.treble - a.treble) * amount,
    spectrum = spectrum,
  }
end

bandOnset = function(hop: analysis.Hop, band: model.Band): number
  local value = if band == 'bass' then hop.bassOnset elseif band == 'mid' then hop.midOnset else hop.trebleOnset
  return if value == value then math.clamp(value, 0, 1) else 0
end

removeOldest = function(onsets: { model.Onset }, band: model.Band): ()
  for index, onset in onsets do
    if onset.band == band then
      table.remove(onsets, index)
      return
    end
  end
end

-- Treble glints spread across a quarter turn around the anchor. Sample time seeds the spread, so a replayed
-- publication would land at the same place and the result does not depend on the render clock.
scatter = function(anchor: number, endFrame: number): number
  local spread = (math.sin(endFrame * 12.9898) * 43758.5453) % 1
  return (anchor + (spread - 0.5) * 0.25) % 1
end

newest = function(snapshot: analysis.Snapshot): number?
  local last = snapshot.latest
  local ending = if last and last.generation == snapshot.generation then last.endFrame else nil
  for _, hop in snapshot.hops do
    if hop.generation == snapshot.generation and (ending == nil or hop.endFrame > ending) then
      ending = hop.endFrame
    end
  end
  return ending
end

return responseChild
