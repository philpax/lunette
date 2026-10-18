-- Turns what the backdrop responds to into the geometry of its two control-panel views. The band skyline shows the
-- level and stereo balance that drive each curtain band, with a few seconds of history, and the sky model marks the
-- facing, the onset anchor and its hold, and each live onset around the head. Everything here is pure: it takes
-- samples and sizes in metres and returns shapes and colours in a volume's coordinates, with x right, y up, and z out
-- of the panel.
local model = require '../rendering/model'

local scene = {}

-- What the backdrop observed in its last frame. A turn is a longitude in [0, 1), increasing to the viewer's left, with
-- 0.5 facing -z.
export type Observed = {
  frame: model.Frame,
  -- The analysed spectrum before smoothing, scaled by the response strength as the frame's spectrum is.
  raw: { number },
  facing: number?,
  -- The longitude onsets scatter about, which holds while the facing stays near it.
  anchor: number?,
}

-- One sampled row of the skyline's history.
export type Row = { read spectrum: { read [number]: number }, read stereo: { read [number]: number } }

export type Color = { number }

-- The backdrop's linear-light band colours.
export type Palette = {
  read bass: { read [number]: number },
  read mid: { read [number]: number },
  read treble: { read [number]: number },
}

-- A box by its centre and size.
export type Bar = {
  read x: number,
  read y: number,
  read z: number,
  read width: number,
  read height: number,
  read depth: number,
  read color: Color,
}

export type Skyline = { read bars: { Bar }, read caps: { Bar } }

-- A rod between two points, or a ball at one, in a model whose origin is the head and whose radius is one.
export type Rod = { read from: vector, read to: vector, read radius: number, read color: Color }
export type Ball = { read at: vector, read radius: number, read color: Color }

export type Markers = { read rods: { Rod }, read balls: { Ball } }

export type Pool = { read band: model.Band, read used: number, read size: number }

export type Summary = { read pools: { Pool }, read discarded: number, read silent: boolean }

-- History rows the skyline keeps, and how often it samples one, in seconds.
scene.ROWS = 24
scene.ROW_INTERVAL = 1 / 20

-- The fraction of each band's slot between its columns and the next band's.
local GAP = 0.25
-- Where each band's onsets sit on the ground of the model, inner to outer like the curtain layers.
local BAND_RING = table.freeze { bass = 0.5, mid = 0.7, treble = 0.9 } :: { read [model.Band]: number }
local BANDS: { model.Band } = table.freeze({ 'bass', 'mid', 'treble' } :: { model.Band })
local COARSE: { model.Band } =
  table.freeze({ 'bass', 'bass', 'bass', 'mid', 'mid', 'mid', 'treble', 'treble' } :: { model.Band })
local WHITE = table.freeze { 1, 1, 1, 1 }

local unit: (number?) -> number
local display: ({ read [number]: number }, number, number) -> Color
local direction: (number, number) -> vector
local bandColor: (Palette, model.Band) -> { read [number]: number }

-- Adds a row to the front of the history, keeping at most `scene.ROWS`.
function scene.push(history: { Row }, row: Row): ()
  table.insert(history, 1, row)
  for index = #history, scene.ROWS + 1, -1 do
    history[index] = nil
  end
end

-- A row from the frame the backdrop drew, copied so the history does not alias the model's tables.
function scene.row(frame: model.Frame): Row
  return { spectrum = table.clone(frame.spectrum :: { number }), stereo = table.clone(frame.stereo :: { number }) }
end

-- Each band is a pair of columns, left channel then right, rising up the panel by level. A side quieter than the
-- other is shorter in proportion, so a centred band stands as two equal columns. The newest row is at the front of
-- the volume and older rows recede toward the panel, fading. A cap marks the analysed level the newest row is
-- moving toward.
function scene.skyline(
  history: { Row },
  raw: { read [number]: number },
  palette: Palette,
  width: number,
  height: number,
  depth: number
): Skyline
  local bars: { Bar } = {}
  local caps: { Bar } = {}
  local slot = width / model.SPECTRUM_BANDS
  local half = slot * (1 - GAP) / 2
  local spacing = depth / scene.ROWS
  local floor = -height / 2
  for age, row in history do
    local z = depth - (age - 0.5) * spacing
    local fade = 1 - 0.85 * (age - 1) / scene.ROWS
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
        color = table.clone(WHITE :: { number }),
      })
    end
  end
  return { bars = bars, caps = caps }
end

-- Marks on the ground of a unit model of the sky: the facing as a needle from the head, the anchor as a rod to the
-- rim with two shorter rods at the bounds of its hold, a tick at each sector's edge, and a ball for each live onset
-- on its band's ring, growing and fading with its age.
function scene.markers(observed: Observed, palette: Palette, sectors: number, hold: number, accent: Color): Markers
  local rods: { Rod } = {}
  local balls: { Ball } = {}
  local ink = table.clone(WHITE :: { number })
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

-- How full each band's onset pool is, how many onsets a full pool skipped, and whether anything is sounding.
function scene.summary(observed: Observed): Summary
  local frame = observed.frame
  local used: { [model.Band]: number } = { bass = 0, mid = 0, treble = 0 }
  for _, wave in frame.waves do
    used[wave.band] += 1
  end
  local pools: { Pool } = {}
  for _, band in BANDS do
    table.insert(pools, { band = band, used = used[band], size = model.wavePools[band] })
  end
  local silent = #frame.waves == 0
  for band = 1, model.SPECTRUM_BANDS do
    silent = silent and unit(observed.raw[band]) == 0 and unit(frame.spectrum[band]) == 0
  end
  return { pools = pools, discarded = frame.discardedHops, silent = silent }
end

function scene.sameSummary(a: Summary, b: Summary): boolean
  if a.discarded ~= b.discarded or a.silent ~= b.silent then
    return false
  end
  for index, pool in a.pools do
    if pool.used ~= b.pools[index].used then
      return false
    end
  end
  return true
end

-- The summary as a caption.
function scene.caption(summary: Summary): string
  if summary.silent then
    return 'Silent.'
  end
  local parts: { string } = {}
  for _, pool in summary.pools do
    table.insert(parts, `{pool.band} {pool.used}/{pool.size}`)
  end
  local text = 'Onsets: ' .. table.concat(parts, ', ')
  return if summary.discarded > 0 then `{text}; {summary.discarded} skipped by full pools` else text
end

unit = function(value: number?): number
  return if value and value == value then math.clamp(value, 0, 1) else 0
end

-- The palette is linear light and a pass colour is sRGB, so each channel is encoded after scaling.
display = function(linear: { read [number]: number }, scale: number, alpha: number): Color
  local color: Color = {}
  for channel = 1, 3 do
    local value = unit((linear[channel] or 0) * scale)
    color[channel] = if value <= 0.0031308 then value * 12.92 else 1.055 * value ^ (1 / 2.4) - 0.055
  end
  color[4] = unit(alpha)
  return color
end

bandColor = function(palette: Palette, band: model.Band): { read [number]: number }
  return if band == 'bass' then palette.bass elseif band == 'mid' then palette.mid else palette.treble
end

-- A longitude's direction is (sin, 0, cos) of its angle, as the backdrop's shaders place it.
direction = function(turn: number, distance: number): vector
  local angle = turn * 2 * math.pi
  return vector.create(math.sin(angle) * distance, 0, math.cos(angle) * distance)
end

return scene
