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

type StoredBar = { x: number, y: number, z: number, width: number, height: number, depth: number, color: Color }
type StoredRod = { from: vector, to: vector, radius: number, color: Color }
type StoredBall = { at: vector, radius: number, color: Color }

export type SkylineBuffer = { read shape: Skyline, read bars: { StoredBar }, read caps: { StoredBar } }
export type MarkerBuffer = {
  read shape: Markers,
  read rods: { StoredRod },
  read balls: { StoredBall },
  read ink: Color,
  read accent: Color,
  read bound: Color,
}

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
local display: (Color, { read [number]: number }, number, number) -> ()
local direction: (number, number) -> vector
local bandColor: (Palette, model.Band) -> { read [number]: number }
local storedBar: ({ StoredBar }, number) -> StoredBar
local storedRod: (MarkerBuffer, number, vector, vector, number, Color) -> ()
local storedBall: (MarkerBuffer, number, vector, number) -> StoredBall
local copyColor: (Color, Color) -> ()

-- Buffers belong to one view. Their shapes remain valid until that buffer is updated again.
function scene.newSkyline(): SkylineBuffer
  return { shape = { bars = {}, caps = {} }, bars = {}, caps = {} }
end

function scene.newMarkers(): MarkerBuffer
  return {
    shape = { rods = {}, balls = {} },
    rods = {},
    balls = {},
    ink = table.clone(WHITE :: { number }),
    accent = {},
    bound = {},
  }
end

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
  depth: number,
  reuse: SkylineBuffer?
): Skyline
  local buffer = reuse or scene.newSkyline()
  local bars, caps = buffer.shape.bars, buffer.shape.caps
  local barCount, capCount = 0, 0
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
      local centre = -width / 2 + (band - 0.5) * slot
      for side = 1, 2 do
        local levelAtSide = if side == 1 then level * (1 - math.max(balance, 0)) else level * (1 + math.min(balance, 0))
        local tall = math.max(height * levelAtSide, height * 0.01)
        barCount += 1
        local bar = storedBar(buffer.bars, barCount)
        bar.x = centre + (side - 1.5) * half
        bar.y, bar.z = floor + tall / 2, z
        bar.width, bar.height, bar.depth = half * 0.9, tall, spacing * 0.6
        display(bar.color, bandColor(palette, COARSE[band]), 0.35 + 0.65 * levelAtSide, fade)
        bars[barCount] = bar
      end
    end
  end
  for band = 1, model.SPECTRUM_BANDS do
    local level = unit(raw[band])
    if level > 0 then
      local thickness = height * 0.012
      capCount += 1
      local cap = storedBar(buffer.caps, capCount)
      cap.x = -width / 2 + (band - 0.5) * slot
      cap.y, cap.z = floor + height * level + thickness / 2, depth - spacing / 2
      cap.width, cap.height, cap.depth = half * 2, thickness, spacing * 0.8
      copyColor(cap.color, WHITE :: { number })
      caps[capCount] = cap
    end
  end
  for index = #bars, barCount + 1, -1 do
    bars[index] = nil
  end
  for index = #caps, capCount + 1, -1 do
    caps[index] = nil
  end
  return buffer.shape
end

-- Marks on the ground of a unit model of the sky: the facing as a needle from the head, the anchor as a rod to the
-- rim with two shorter rods at the bounds of its hold, a tick at each sector's edge, and a ball for each live onset
-- on its band's ring, growing and fading with its age.
function scene.markers(
  observed: Observed,
  palette: Palette,
  sectors: number,
  hold: number,
  accent: Color,
  reuse: MarkerBuffer?
): Markers
  local buffer = reuse or scene.newMarkers()
  local rods, balls = buffer.shape.rods, buffer.shape.balls
  local rodCount, ballCount = 0, 1
  local ink, bound = buffer.ink, buffer.bound
  copyColor(buffer.accent, accent)
  copyColor(bound, accent)
  bound[4] = (bound[4] or 1) * 0.5
  for sector = 0, sectors - 1 do
    local turn = (sector + 0.5) / sectors
    rodCount += 1
    storedRod(buffer, rodCount, direction(turn, 0.94), direction(turn, 1.08), 0.02, ink)
  end
  local anchor = observed.anchor
  if anchor then
    rodCount += 1
    storedRod(buffer, rodCount, vector.zero, direction(anchor, 1.08), 0.03, buffer.accent)
    rodCount += 1
    storedRod(
      buffer,
      rodCount,
      direction(anchor - hold / sectors, 0.3),
      direction(anchor - hold / sectors, 1),
      0.015,
      bound
    )
    rodCount += 1
    storedRod(
      buffer,
      rodCount,
      direction(anchor + hold / sectors, 0.3),
      direction(anchor + hold / sectors, 1),
      0.015,
      bound
    )
  end
  if observed.facing then
    rodCount += 1
    storedRod(buffer, rodCount, vector.zero, direction(observed.facing, 0.6), 0.04, ink)
  end
  local head = storedBall(buffer, 1, vector.zero, 0.08)
  copyColor(head.color, ink)
  for _, wave in observed.frame.waves do
    local progress = if wave.lifetime > 0 then math.clamp(wave.age / wave.lifetime, 0, 1) else 1
    ballCount += 1
    local ball = storedBall(buffer, ballCount, direction(wave.position, BAND_RING[wave.band]), 0.06 + 0.1 * progress)
    display(ball.color, bandColor(palette, wave.band), 1, unit(wave.strength) * (1 - progress))
  end
  for index = #rods, rodCount + 1, -1 do
    rods[index] = nil
  end
  for index = #balls, ballCount + 1, -1 do
    balls[index] = nil
  end
  return buffer.shape
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
display = function(color: Color, linear: { read [number]: number }, scale: number, alpha: number): ()
  for channel = 1, 3 do
    local value = unit((linear[channel] or 0) * scale)
    color[channel] = if value <= 0.0031308 then value * 12.92 else 1.055 * value ^ (1 / 2.4) - 0.055
  end
  color[4] = unit(alpha)
end

bandColor = function(palette: Palette, band: model.Band): { read [number]: number }
  return if band == 'bass' then palette.bass elseif band == 'mid' then palette.mid else palette.treble
end

-- A longitude's direction is (sin, 0, cos) of its angle, as the backdrop's shaders place it.
direction = function(turn: number, distance: number): vector
  local angle = turn * 2 * math.pi
  return vector.create(math.sin(angle) * distance, 0, math.cos(angle) * distance)
end

storedBar = function(pool: { StoredBar }, index: number): StoredBar
  local bar = pool[index]
  if not bar then
    bar = { x = 0, y = 0, z = 0, width = 0, height = 0, depth = 0, color = {} }
    pool[index] = bar
  end
  return bar
end

storedRod = function(buffer: MarkerBuffer, index: number, from: vector, to: vector, radius: number, color: Color): ()
  local rod = buffer.rods[index]
  if not rod then
    rod = { from = from, to = to, radius = radius, color = color }
    buffer.rods[index] = rod
  else
    rod.from, rod.to, rod.radius, rod.color = from, to, radius, color
  end
  buffer.shape.rods[index] = rod
end

storedBall = function(buffer: MarkerBuffer, index: number, at: vector, radius: number): StoredBall
  local ball = buffer.balls[index]
  if not ball then
    ball = { at = at, radius = radius, color = {} }
    buffer.balls[index] = ball
  else
    ball.at, ball.radius = at, radius
  end
  buffer.shape.balls[index] = ball
  return ball
end

copyColor = function(target: Color, source: Color): ()
  for index = 1, #source do
    target[index] = source[index]
  end
  for index = #target, #source + 1, -1 do
    target[index] = nil
  end
end

return scene
