-- Prepares onset travel and decay once per frame instead of in each shader invocation.
local model = require './model'

local uniforms = {}

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
