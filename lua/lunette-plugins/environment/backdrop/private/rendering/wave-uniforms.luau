-- Prepares onset travel and decay once per frame instead of in each shader invocation.
local model = require './model'

local uniforms = {}
local BAND_INDEX = table.freeze { bass = 1, mid = 2, treble = 3 } :: { read [model.Band]: number }

-- The model supplies a contiguous array of waves with a closed Band union. Stable grouping preserves each
-- shader accumulator's term order without changing the model's chronological wave order.
function uniforms.prepare(
  source: { model.Wave },
  responseStrength: number
): ({ { number } }, { { number } }, { number }, number)
  local live = math.min(#source, model.MAX_WAVES)
  local slots: { [model.Band]: number } = { bass = 0, mid = 0, treble = 0 }
  for index = 1, live do
    slots[source[index].band] += 1
  end
  local bassEnd, midEnd = slots.bass, slots.bass + slots.mid
  local ends = { bassEnd, midEnd, live, 0 }
  slots.bass, slots.mid, slots.treble = 0, bassEnd, midEnd
  local waves = table.create(model.MAX_WAVES) :: { { number } }
  local details = table.create(model.MAX_WAVES) :: { { number } }
  for index = 1, live do
    local wave = source[index]
    local band = wave.band
    local slot = slots[band] + 1
    slots[band] = slot
    waves[slot] = {
      wave.age,
      wave.strength * (1 - wave.age / wave.lifetime) * responseStrength,
      wave.position,
      BAND_INDEX[band],
    }
    details[slot] = uniforms.detail(wave)
  end
  for index = live + 1, model.MAX_WAVES do
    waves[index], details[index] = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
  end
  return waves, details, ends, live
end

function uniforms.detail(wave: model.Wave): { number }
  local detail = math.clamp(wave.frequency, 0, 1)
  local speed = if wave.band == 'bass' then 0.3 else 0.16
  local decay = if wave.band == 'bass' then 1.2 else if wave.band == 'mid' then 1.5 else 3
  local rise = math.clamp(wave.age / 0.08, 0, 1)
  return {
    detail,
    wave.age * speed * (0.9 + 0.2 * detail),
    math.exp(-wave.age * decay) * (if wave.band == 'treble' then rise * rise * (3 - 2 * rise) else 1),
    math.exp(-wave.age * 8),
  }
end

return uniforms
