local testing = require '@testing'
local config = require '../config'
local model = require '../private/rendering/model'
local scene = require '../private/visualisation/scene'
local expect = testing.expect
local test = testing.suite()

local palette = config.schema.parse({}).palette

local function row(level: number, stereo: number): scene.Row
  return {
    spectrum = table.create(model.SPECTRUM_BANDS, level),
    stereo = table.create(model.SPECTRUM_BANDS, stereo),
  }
end

local function frame(waves: { model.Wave }?): model.Frame
  local state = model.new(config.schema.parse {})
  local current = state:update(0, true)
  return table.freeze {
    visibility = current.visibility,
    time = current.time,
    bass = 0,
    mid = 0,
    treble = 0,
    brightness = 1,
    spectrum = current.spectrum,
    stereo = current.stereo,
    responseStrength = 1,
    onsetGap = nil,
    discardedHops = 0,
    waves = waves or {},
  } :: any
end

test('a centred band stands as two equal columns at its level, and a balanced one leans to its louder side', function()
  local shape = scene.skyline({ row(0.5, 0) }, table.create(8, 0), palette, 0.8, 0.1, 0.05)
  expect.equal(#shape.bars, model.SPECTRUM_BANDS * 2, 'two columns per band')
  expect.near(shape.bars[1].height, 0.05, 1e-9, 'the left column at half the height')
  expect.near(shape.bars[2].height, 0.05, 1e-9, 'the right column the same')
  expect.near(shape.bars[1].y - shape.bars[1].height / 2, -0.05, 1e-9, 'columns stand on the floor')
  local right = scene.skyline({ row(0.5, 0.25) }, table.create(8, 0), palette, 0.8, 0.1, 0.05)
  expect.near(right.bars[1].height, 0.025, 1e-9, 'the quieter left side is shorter by the balance')
  expect.near(right.bars[2].height, 0.05, 1e-9, 'the louder right side keeps the level')
  local left = scene.skyline({ row(0.5, -0.5) }, table.create(8, 0), palette, 0.8, 0.1, 0.05)
  expect.near(left.bars[1].height, 0.05, 1e-9)
  expect.near(left.bars[2].height, 0.001, 1e-9, 'a wholly left band leaves a sliver on the right')
end)

test('the newest row is at the front of the volume, older rows recede and fade, and caps mark the raw level', function()
  local history: { scene.Row } = {}
  for index = 1, scene.ROWS + 5 do
    scene.push(history, row(index / 100, 0))
  end
  expect.equal(#history, scene.ROWS, 'the history is bounded')
  expect.near(history[1].spectrum[1], (scene.ROWS + 5) / 100, 1e-9, 'the newest row is first')
  local raw = table.create(8, 0)
  raw[3] = 0.75
  local shape = scene.skyline(history, raw, palette, 0.8, 0.1, 0.048)
  local newest, oldest = shape.bars[1], shape.bars[#shape.bars]
  expect.near(newest.z, 0.048 - 0.001, 1e-9, 'the newest row sits half a row inside the front')
  expect.truthy(oldest.z > 0 and oldest.z < newest.z, 'the oldest row is nearest the panel')
  expect.truthy(oldest.color[4] < newest.color[4], 'older rows are more transparent')
  for _, bar in shape.bars do
    expect.truthy(bar.z + bar.depth / 2 <= 0.048 and bar.z - bar.depth / 2 >= 0, 'bars stay within the depth')
    expect.truthy(math.abs(bar.x) + bar.width / 2 <= 0.4, 'bars stay within the width')
  end
  expect.equal(#shape.caps, 1, 'one cap for the one sounding raw band')
  expect.near(shape.caps[1].y, -0.05 + 0.075 + 0.0006, 1e-9, 'the cap sits at the raw level')
end)

test('the model marks the facing, the anchor and its hold, each sector edge, and live onsets on their rings', function()
  local observed: scene.Observed = {
    frame = frame {
      { age = 0, strength = 1, position = 0.25, band = 'bass', lifetime = 0.9, frequency = 0.5 },
      { age = 0.6, strength = 1, position = 0.5, band = 'treble', lifetime = 0.9, frequency = 0.5 },
    },
    raw = table.create(8, 0),
    facing = 0.5,
    anchor = 0.5,
  }
  local markers = scene.markers(observed, palette, 12, 0.65, { 0, 0, 1, 1 })
  expect.equal(#markers.rods, 12 + 3 + 1, 'sector ticks, the anchor with its two bounds, and the facing needle')
  local needle = markers.rods[#markers.rods]
  expect.near(needle.to.z, -0.6, 1e-6, 'facing 0.5 points to -z')
  expect.near(needle.to.x, 0, 1e-6)
  local anchor = markers.rods[13]
  expect.near(anchor.to.z, -1.08, 1e-6, 'the anchor reaches past the rim')
  local bound = markers.rods[14]
  local angle = math.atan2(bound.to.x, bound.to.z) / (2 * math.pi) % 1
  expect.near(angle, 0.5 - 0.65 / 12, 1e-6, 'the hold reaches 0.65 of a sector either side')
  expect.equal(#markers.balls, 3, 'the head and two onsets')
  local bass, treble = markers.balls[2], markers.balls[3]
  expect.near(bass.at.x, 1 * 0.5, 1e-6, 'a quarter turn lies along +x, on the bass ring')
  expect.near(vector.magnitude(treble.at), 0.9, 1e-6, 'treble sits on the outer ring')
  expect.truthy(treble.radius > bass.radius, 'an older onset has grown')
  expect.truthy(treble.color[4] < bass.color[4], 'and faded')
end)

test('the summary counts each pool, the skipped onsets, and silence', function()
  local observed: scene.Observed = {
    frame = frame {
      { age = 0, strength = 1, position = 0.25, band = 'mid', lifetime = 1.2, frequency = 0.5 },
    },
    raw = table.create(8, 0),
  }
  local summary = scene.summary(observed)
  expect.equal(summary.pools[2].used, 1)
  expect.equal(summary.pools[2].size, model.wavePools.mid)
  expect.equal(summary.silent, false, 'a live onset is sound')
  expect.equal(scene.caption(summary), 'Onsets: bass 0/4, mid 1/8, treble 0/8')
  local quiet = scene.summary { frame = frame(), raw = table.create(8, 0) }
  expect.equal(quiet.silent, true)
  expect.equal(scene.caption(quiet), 'Nothing is sounding.')
  expect.equal(scene.sameSummary(summary, quiet), false)
  expect.equal(scene.sameSummary(summary, scene.summary(observed)), true)
end)

return test
