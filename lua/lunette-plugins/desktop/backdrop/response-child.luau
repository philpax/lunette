-- The optional analysis consumer owns at most two readers; source policy is supplied data.
local plugin = require '@lunette-plugin'
local analysis = require '@lunette-contracts/audio-analysis'
local frame = require '@lunette-contracts/frame'
local config = require './config'
local model = require './model'
local selection = require './selection'

local responseChild = {}
type Slot = {
  reader: analysis.Reader,
  generation: number?,
  endFrame: number?,
  publication: number?,
  -- Sample end of each band's last onset hop in the current stream generation.
  lastOnset: { [model.Band]: number },
}
local ZERO: model.Features = table.freeze {
  bass = 0,
  mid = 0,
  treble = 0,
  spectrum = table.freeze(table.create(model.SPECTRUM_BANDS, 0)),
}
-- One transient often completes two or three adjacent 512-sample hops; onsets this close are one event.
local MERGE_FRAMES = 1200
-- Onsets anchor to the sector the viewer faces. A sector is a twelfth of a turn, and the anchor moves only once
-- the view is past the sector's edge by a further 15 percent of its width, so onsets follow a turn of the head
-- without chasing every small movement.
local SECTORS = 12
local SECTOR_HOLD = 0.65
-- Full width, in turns, of each band's scatter about the anchor.
local SCATTER = table.freeze { bass = 0.05, mid = 0.08, treble = 0.16 } :: { read [model.Band]: number }
local BANDS: { model.Band } = table.freeze({ 'bass', 'mid', 'treble' } :: { model.Band })
-- Narrow bands hold less power than the coarse bands, and recorded music falls off steeply above 2 kHz. The
-- fixed calibration brings a typical mastered mix near half scale in every band; it was measured on a
-- system-output capture of commercial music, not derived from a model of the spectrum.
local SPECTRUM_GAINS = table.freeze { 8, 6, 5, 5.5, 6.5, 7, 13, 13 }
local same: (analysis.Source?, analysis.Source?) -> boolean
local mapped: (analysis.Steady) -> model.Features
local power: (number, number) -> number
local mixed: (model.Features, model.Features, number) -> model.Features
local bandOnset: (analysis.Hop, model.Band) -> number
local removeOldest: ({ model.Onset }, model.Band) -> ()
local scatter: (number, number, model.Band) -> number
local newestBand: ({ model.Onset }, model.Band) -> number?

function responseChild.new(
  choice: selection.State,
  state: model.State,
  settings: config.Settings,
  needed: () -> boolean,
  facing: () -> number?
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
      local anchor: number? = nil
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
          generation = publication.generation,
          lastOnset = {},
          endFrame = nil,
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
          anchor = responseChild.sector(anchor, facing())
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
            if snapshot.gap then
              -- The analysis reset its history and the model clears its waves, so no earlier onset remains.
              table.clear(slot.lastOnset)
            end
            slot.publication = snapshot.frameGeneration
            if slot.generation ~= snapshot.generation then
              gap = 'publication'
              slot.generation, slot.endFrame = snapshot.generation, nil
              table.clear(slot.lastOnset)
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
                  local previous = slot.lastOnset[band]
                  local adjacent = previous ~= nil and hop.endFrame - previous <= MERGE_FRAMES
                  if strength > 0 then
                    slot.lastOnset[band] = hop.endFrame
                  end
                  if strength > 0 and adjacent then
                    -- The transient already has a wave. Raise it if this publication delivers it, else drop.
                    local index = newestBand(onsets, band)
                    if index then
                      local earlier = onsets[index]
                      onsets[index] = {
                        strength = math.max(earlier.strength, strength * weight),
                        position = earlier.position,
                        age = earlier.age,
                        band = band,
                      }
                    end
                  elseif strength > 0 then
                    if counts[band] == model.wavePools[band] then
                      removeOldest(onsets, band)
                      discarded += 1
                      gap = 'capacity'
                    else
                      counts[band] += 1
                    end
                    onsets[#onsets + 1] = {
                      strength = strength * weight,
                      position = scatter(anchor or 0.5, hop.endFrame, band),
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

-- The anchor longitude for a facing longitude, given the current anchor. Without a facing, the anchor holds, and
-- without either, onsets face -z, LÖVR's forward direction.
function responseChild.sector(current: number?, facing: number?): number?
  if facing == nil or facing ~= facing or math.abs(facing) == math.huge then
    return current
  end
  if current then
    local offset = math.abs((facing - current + 0.5) % 1 - 0.5)
    if offset <= SECTOR_HOLD / SECTORS then
      return current
    end
  end
  return (math.floor(facing * SECTORS + 0.5) % SECTORS) / SECTORS
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

newestBand = function(onsets: { model.Onset }, band: model.Band): number?
  for index = #onsets, 1, -1 do
    if onsets[index].band == band then
      return index
    end
  end
  return nil
end

removeOldest = function(onsets: { model.Onset }, band: model.Band): ()
  for index, onset in onsets do
    if onset.band == band then
      table.remove(onsets, index)
      return
    end
  end
end

-- Onsets scatter about the anchor, treble widest. Sample time and band seed the offset, so a replayed publication
-- lands in the same place, the result does not depend on the render clock, and bands struck by one transient start
-- apart.
scatter = function(anchor: number, endFrame: number, band: model.Band): number
  local salt = if band == 'bass' then 0 elseif band == 'mid' then 1.618 else 3.236
  local spread = (math.sin(endFrame * 12.9898 + salt * 78.233) * 43758.5453) % 1 - 0.5
  return (anchor + spread * SCATTER[band]) % 1
end

return responseChild
