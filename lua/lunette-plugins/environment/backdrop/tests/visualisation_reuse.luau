local testing = require '@testing'
local scene = require '../private/visualisation/scene'
local model = require '../private/rendering/model'
local oracle = require './support/scene-oracle'
local expect = testing.expect
local test = testing.suite()

local palette: scene.Palette = { bass = { 0.001, 0.2, 1 }, mid = { 0.4, 0.5, 0.6 }, treble = { 1, 0.1, 0 } }
local accent: scene.Color = { 0.3, 0.7, 1, 0.8 }
local invalid: scene.Palette = { bass = { 0 / 0, math.huge, -math.huge }, mid = {}, treble = { -1, 2, 0.0031308 } }

local function same(actual: unknown, expected: unknown, path: string?): ()
  path = path or 'shape'
  expect.equal(type(actual), type(expected), path .. ' type')
  if type(expected) == 'table' then
    local actualTable = actual :: { [any]: unknown }
    local expectedTable = expected :: { [any]: unknown }
    local count = 0
    for key, value in expectedTable do
      count += 1
      same(actualTable[key], value, path .. '.' .. tostring(key))
    end
    local actualCount = 0
    for _ in actualTable do
      actualCount += 1
    end
    expect.equal(actualCount, count, path .. ' field count')
  elseif typeof(expected) == 'vector' then
    local actualVector = actual :: any
    local expectedVector = expected :: vector
    same(actualVector.x, expectedVector.x, path .. '.x')
    same(actualVector.y, expectedVector.y, path .. '.y')
    same(actualVector.z, expectedVector.z, path .. '.z')
  elseif type(expected) == 'number' then
    local actualNumber = actual :: number
    local expectedNumber = expected :: number
    if expectedNumber ~= expectedNumber then
      expect.truthy(actualNumber ~= actualNumber, path .. ' NaN')
    else
      expect.equal(actualNumber, expectedNumber, path)
    end
  else
    expect.equal(actual, expected, path)
  end
end

local function remember(value: unknown, identities: { [table]: boolean }): number
  if type(value) ~= 'table' then
    return 0
  end
  local current = value :: { [any]: unknown }
  if identities[current] then
    return 0
  end
  identities[current] = true
  local count = 1
  for _, child in current do
    count += remember(child, identities)
  end
  return count
end

local function history(count: number): { scene.Row }
  local rows = {}
  for age = 1, count do
    local spectrum, stereo = {}, {}
    for band = 1, 8 do
      spectrum[band] = ((age * 13 + band * 7) % 31 - 3) / 24
      stereo[band] = ((age * 3 + band * 11) % 19 - 9) / 8
    end
    rows[age] = { spectrum = spectrum, stereo = stereo }
  end
  return rows
end

local function observed(count: number): scene.Observed
  local waves: { model.Wave } = {}
  local bands: { model.Band } = { 'bass', 'mid', 'treble' }
  for index = 1, count do
    waves[index] = {
      band = bands[(index - 1) % 3 + 1],
      age = (index % 7 - 1) / 5,
      lifetime = (index % 4) / 3,
      strength = (index % 5 - 1) / 3,
      position = index / 7,
      frequency = 0.5,
    }
  end
  return {
    frame = { waves = waves } :: any,
    raw = {},
    facing = 0.25,
    anchor = 0.5,
  }
end

local function skyline(
  rows: { scene.Row },
  raw: { number },
  colors: scene.Palette,
  dimensions: { number },
  reuse: scene.SkylineBuffer?
): scene.Skyline
  return scene.skyline(rows, raw, colors, dimensions[1], dimensions[2], dimensions[3], reuse)
end

local function skylineOracle(
  rows: { scene.Row },
  raw: { number },
  colors: scene.Palette,
  dimensions: { number }
): scene.Skyline
  return oracle.skyline(rows, raw, colors, dimensions[1], dimensions[2], dimensions[3])
end

test('reused skyline geometry agrees with the oracle for empty, sparse, full, and invalid input', function()
  local buffer = scene.newSkyline()
  local raw = { 0, 0.7, -1, 2, 0 / 0, math.huge, -math.huge }
  for _, count in { 0, 1, 24, 3, 0, 24 } do
    local rows = history(count)
    if count > 0 then
      rows[1] = { spectrum = { 0 / 0, math.huge, -math.huge, 1, 0.5 }, stereo = { 0, 1, -1, 0 / 0 } }
    end
    for _, colors in { palette, invalid } do
      for _, dimensions in { { 0.8, 0.1, 0.05 }, { 0, 0, 0 }, { 1.6, 0.5, 0.2 } } do
        local shape = skyline(rows, raw, colors, dimensions, buffer)
        same(shape, skylineOracle(rows, raw, colors, dimensions))
      end
    end
  end
end)

test('reused markers agree with the oracle through onset, orientation, sector, and accent changes', function()
  local buffer = scene.newMarkers()
  for _, count in { 0, 1, 24, 3, 0, 24 } do
    local state = observed(count)
    for _, sectors in { 0, 1, 12, 32 } do
      for _, colors in { palette, invalid } do
        local shape = scene.markers(state, colors, sectors, 0.65, accent, buffer)
        same(shape, oracle.markers(state, colors, sectors, 0.65, accent))
        state.facing, state.anchor = nil, nil
        shape = scene.markers(state, colors, sectors, 0, { 1, 0.2, 0.4 }, buffer)
        same(shape, oracle.markers(state, colors, sectors, 0, { 1, 0.2, 0.4 }))
      end
    end
  end
end)

test('warm skyline and marker buffers retain all geometry and color tables after shrinking and regrowing', function()
  local rows, raw = history(24), table.create(8, 1)
  local state = observed(24)
  local skyBuffer, markerBuffer = scene.newSkyline(), scene.newMarkers()
  local shape = scene.skyline(rows, raw, palette, 0.8, 0.1, 0.05, skyBuffer)
  local marks = scene.markers(state, palette, 32, 0.65, accent, markerBuffer)
  local identities: { [table]: boolean } = {}
  local warmTables = remember(skyBuffer, identities) + remember(markerBuffer, identities)
  local fresh = 0
  for index = 1, 60 do
    local small = index % 2 == 0
    local nextShape =
      scene.skyline(if small then {} else rows, if small then {} else raw, palette, 1, 0.2, 0.1, skyBuffer)
    local nextMarks =
      scene.markers(if small then observed(0) else state, invalid, if small then 1 else 32, 0.2, accent, markerBuffer)
    expect.equal(nextShape, shape, 'the skyline result is retained')
    expect.equal(nextMarks, marks, 'the marker result is retained')
    fresh += remember(skyBuffer, identities) + remember(markerBuffer, identities)
    expect.equal(#nextShape.bars, if small then 0 else 384, 'only current bars remain visible')
    expect.equal(#nextShape.caps, if small then 0 else 8, 'only current caps remain visible')
    expect.equal(#nextMarks.balls, if small then 1 else 25, 'only current onsets remain visible')
  end
  expect.equal(fresh, 0, 'no geometry or color table is allocated after warmup')
  expect.truthy(warmTables > 800, 'the regression exercises the full geometry')
end)

test(
  'reused shapes read current raw levels, dimensions, palette, and accent without mutating other instances',
  function()
    local rows, raw = history(1), { 0.5 }
    local colors: scene.Palette = { bass = { 0.1, 0.2, 0.3 }, mid = palette.mid, treble = palette.treble }
    local dimensions = { 0.8, 0.1, 0.05 }
    local skyBuffer = scene.newSkyline()
    local first = skyline(rows, raw, colors, dimensions, skyBuffer)
    local second = skyline(rows, raw, colors, dimensions)
    local secondExpected = skylineOracle(rows, raw, colors, dimensions)
    raw[1], raw[8], colors.bass[1] = 0, 0.9, 1
    dimensions[1], dimensions[2], dimensions[3] = 1.6, 0.2, 0.1
    skyline(rows, raw, colors, dimensions, skyBuffer)
    same(first, skylineOracle(rows, raw, colors, dimensions))
    same(second, secondExpected)
    local state = observed(2)
    local ink: scene.Color = { 0.2, 0.3, 0.4, 1 }
    local markerBuffer = scene.newMarkers()
    local marks = scene.markers(state, colors, 12, 0.65, ink, markerBuffer)
    local other = scene.markers(state, colors, 12, 0.65, ink)
    local expected = oracle.markers(state, colors, 12, 0.65, table.clone(ink))
    ink[1], ink[4], state.facing, state.anchor = 1, 0.2, 0.1, 0.8
    state.frame.waves = observed(1).frame.waves
    scene.markers(state, invalid, 1, 0.2, ink, markerBuffer)
    same(marks, oracle.markers(state, invalid, 1, 0.2, ink))
    same(other, expected)
  end
)

test('full-history geometry eliminates the oracle allocation volume after warmup', function()
  local rows, raw = history(24), table.create(8, 1)
  local state = observed(24)
  local oldSkyline = remember(oracle.skyline(rows, raw, palette, 0.8, 0.1, 0.05), {})
  local oldMarkers = remember(oracle.markers(state, palette, 32, 0.65, accent), {})
  expect.equal(oldSkyline, 787, 'the oracle allocates 384 bars, 8 caps, their colors, and three shape tables')
  expect.equal(oldMarkers, 91, 'the oracle allocates marker records, onset colors, and shape tables')
  local skyBuffer, markerBuffer = scene.newSkyline(), scene.newMarkers()
  scene.skyline(rows, raw, palette, 0.8, 0.1, 0.05, skyBuffer)
  scene.markers(state, palette, 32, 0.65, accent, markerBuffer)
  collectgarbage 'collect'
  collectgarbage 'stop'
  local before = collectgarbage 'count'
  local ok, problem = pcall(function(): ()
    for _ = 1, 120 do
      scene.skyline(rows, raw, palette, 0.8, 0.1, 0.05, skyBuffer)
      scene.markers(state, palette, 32, 0.65, accent, markerBuffer)
    end
  end)
  local allocated = collectgarbage 'count' - before
  collectgarbage 'restart'
  assert(ok, problem)
  expect.truthy(allocated <= 1, '120 warmed skyline and marker updates increase the heap by at most 1 KiB')
  print(
    `backdrop geometry: oracle {oldSkyline + oldMarkers} reachable tables/frame; warmed 120 updates {allocated} KiB`
  )
end)

return test
