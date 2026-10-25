-- Independent geometry oracle for the control-panel views.
local model = require '../../private/rendering/model'
local scene = require '../../private/visualisation/scene'

local oracle = {}
local ROWS = 24
local COARSE: { model.Band } = { 'bass', 'bass', 'bass', 'mid', 'mid', 'mid', 'treble', 'treble' }
local BAND_RING: { [model.Band]: number } = { bass = 0.5, mid = 0.7, treble = 0.9 }
local WHITE: { number } = { 1, 1, 1, 1 }

local function unit(value: number?): number
  return if value and value == value then math.clamp(value, 0, 1) else 0
end

local function display(linear: { read [number]: number }, scale: number, alpha: number): { number }
  local color = {}
  for channel = 1, 3 do
    local value = unit((linear[channel] or 0) * scale)
    color[channel] = if value <= 0.0031308 then value * 12.92 else 1.055 * value ^ (1 / 2.4) - 0.055
  end
  color[4] = unit(alpha)
  return color
end

local function bandColor(palette: scene.Palette, band: model.Band): { read [number]: number }
  return if band == 'bass' then palette.bass elseif band == 'mid' then palette.mid else palette.treble
end

local function direction(turn: number, distance: number): vector
  local angle = turn * 2 * math.pi
  return vector.create(math.sin(angle) * distance, 0, math.cos(angle) * distance)
end

function oracle.skyline(
  history: { scene.Row },
  raw: { read [number]: number },
  palette: scene.Palette,
  width: number,
  height: number,
  depth: number
): scene.Skyline
  local bars, caps = {}, {}
  local slot = width / model.SPECTRUM_BANDS
  local half = slot * (1 - 0.25) / 2
  local spacing = depth / ROWS
  local floor = -height / 2
  for age, row in history do
    local z = depth - (age - 0.5) * spacing
    local fade = 1 - 0.85 * (age - 1) / ROWS
    for band = 1, model.SPECTRUM_BANDS do
      local level = unit(row.spectrum[band])
      local balance = if level > 0 then math.clamp((row.stereo[band] or 0) / level, -1, 1) else 0
      local sides = { level * (1 - math.max(balance, 0)), level * (1 + math.min(balance, 0)) }
      local centre = -width / 2 + (band - 0.5) * slot
      for side = 1, 2 do
        local tall = math.max(height * sides[side], height * 0.01)
        table.insert(bars, {
          x = centre + (side - 1.5) * half,
          y = floor + tall / 2,
          z = z,
          width = half * 0.9,
          height = tall,
          depth = spacing * 0.6,
          color = display(bandColor(palette, COARSE[band]), 0.35 + 0.65 * sides[side], fade),
        })
      end
    end
  end
  for band = 1, model.SPECTRUM_BANDS do
    local level = unit(raw[band])
    if level > 0 then
      local thickness = height * 0.012
      table.insert(caps, {
        x = -width / 2 + (band - 0.5) * slot,
        y = floor + height * level + thickness / 2,
        z = depth - spacing / 2,
        width = half * 2,
        height = thickness,
        depth = spacing * 0.8,
        color = table.clone(WHITE),
      })
    end
  end
  return { bars = bars, caps = caps }
end

function oracle.markers(
  observed: scene.Observed,
  palette: scene.Palette,
  sectors: number,
  hold: number,
  accent: scene.Color
): scene.Markers
  local rods, balls = {}, {}
  local ink = table.clone(WHITE)
  for sector = 0, sectors - 1 do
    local turn = (sector + 0.5) / sectors
    table.insert(rods, { from = direction(turn, 0.94), to = direction(turn, 1.08), radius = 0.02, color = ink })
  end
  local anchor = observed.anchor
  if anchor then
    table.insert(rods, { from = vector.zero, to = direction(anchor, 1.08), radius = 0.03, color = accent })
    local bound = table.clone(accent)
    bound[4] = (bound[4] or 1) * 0.5
    table.insert(rods, {
      from = direction(anchor - hold / sectors, 0.3),
      to = direction(anchor - hold / sectors, 1),
      radius = 0.015,
      color = bound,
    })
    table.insert(rods, {
      from = direction(anchor + hold / sectors, 0.3),
      to = direction(anchor + hold / sectors, 1),
      radius = 0.015,
      color = bound,
    })
  end
  if observed.facing then
    table.insert(rods, { from = vector.zero, to = direction(observed.facing, 0.6), radius = 0.04, color = ink })
  end
  table.insert(balls, { at = vector.zero, radius = 0.08, color = ink })
  for _, wave in observed.frame.waves do
    local progress = if wave.lifetime > 0 then math.clamp(wave.age / wave.lifetime, 0, 1) else 1
    table.insert(balls, {
      at = direction(wave.position, BAND_RING[wave.band]),
      radius = 0.06 + 0.1 * progress,
      color = display(bandColor(palette, wave.band), 1, unit(wave.strength) * (1 - progress)),
    })
  end
  return { rods = rods, balls = balls }
end

return oracle
