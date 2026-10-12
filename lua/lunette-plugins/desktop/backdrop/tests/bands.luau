local testing = require '@testing'
local expect = testing.expect
local config = require '../config'
local model = require '../model'

local test = testing.suite()
local ZERO: model.Features = { bass = 0, mid = 0, treble = 0 }

local function new(given: config.Config?): model.State
  return model.new(config.schema.parse(given or {}))
end

local function count(waves: { model.Wave }, band: model.Band): number
  local total = 0
  for _, wave in waves do
    total += if wave.band == band then 1 else 0
  end
  return total
end

test('treble floods cannot evict a bass heave or a mid flare', function()
  local state = new()
  state:setFeatures(ZERO, { { strength = 1, band = 'bass' }, { strength = 1, band = 'mid' } })
  for index = 1, 30 do
    state:setFeatures(ZERO, { { strength = 1, position = index / 30, band = 'treble' } })
  end
  expect.equal(count(state.waves, 'bass'), 1, 'bass heave retained')
  expect.equal(count(state.waves, 'mid'), 1, 'mid flare retained')
  expect.equal(count(state.waves, 'treble'), model.wavePools.treble, 'treble pool bounded')
  expect.equal(state.discardedHops, 30 - model.wavePools.treble, 'each evicted glint is counted')
  expect.equal(#state.waves, 2 + model.wavePools.treble, 'total bounded by the pools')
end)

test('a publication over one band pool keeps that band newest and leaves other bands', function()
  local state = new()
  state:setFeatures(ZERO, { { strength = 1, band = 'mid', position = 0.1 } })
  local onsets: { model.Onset } = {}
  for index = 1, 6 do
    onsets[index] = { strength = 1, band = 'bass', position = index / 10 }
  end
  state:setFeatures(ZERO, onsets)
  expect.equal(count(state.waves, 'bass'), model.wavePools.bass, 'bass pool bounded')
  expect.equal(count(state.waves, 'mid'), 1, 'mid untouched by bass overflow')
  expect.equal(state.onsetGap, 'capacity', 'overflow is explicit')
  expect.equal(state.discardedHops, 6 - model.wavePools.bass, 'overflow count')
  local positions = {}
  for _, wave in state.waves do
    if wave.band == 'bass' then
      table.insert(positions, wave.position)
    end
  end
  expect.equal(positions[1], 0.3, 'oldest surviving bass onset')
  expect.equal(positions[#positions], 0.6, 'newest bass onset')
end)

test('each band wave expires after its own lifetime', function()
  for _, band in { 'bass', 'mid', 'treble' } :: { model.Band } do
    local state = new()
    state:setFeatures(ZERO, { { strength = 1, band = band } })
    state:update(model.waveLifetimes[band] * 0.99, false)
    expect.equal(count(state.waves, band), 1, band .. ' wave lives until its lifetime')
    state:update(model.waveLifetimes[band] * 0.02, false)
    expect.equal(count(state.waves, band), 0, band .. ' wave expires at its lifetime')
  end
  local state = new()
  state:setFeatures(ZERO, { { strength = 1, band = 'treble', age = model.waveLifetimes.treble } })
  expect.equal(#state.waves, 0, 'an onset already older than its lifetime is not delivered')
end)

test('without a spectrum each coarse band fills its own spectrum bands', function()
  local state = new { response = 1, attackDuration = 0 }
  state:setFeatures { bass = 0.8, mid = 0.4, treble = 0.2 }
  local frame = state:update(0.01, false)
  for band, expected in { 0.8, 0.8, 0.8, 0.4, 0.4, 0.4, 0.2, 0.2 } do
    expect.near(frame.spectrum[band], expected, 1e-12, 'spectrum band ' .. band)
  end
end)

test('the spectrum follows the configured envelope and response strength', function()
  local state = new { response = 0.5 }
  state:setFeatures { bass = 0, mid = 0, treble = 0, spectrum = { 1, 0, 0, 0, 0, 0, 0, 2 } }
  local frame = state:update(0.06, false)
  expect.near(frame.spectrum[1], (1 - math.exp(-1)) * 0.5, 1e-8, 'attack time constant and strength')
  expect.near(frame.spectrum[8], (1 - math.exp(-1)) * 0.5, 1e-8, 'values clamp to one before smoothing')
  expect.equal(frame.spectrum[4], 0, 'unlit band')
  state:setFeatures { bass = 0, mid = 0, treble = 0, spectrum = { 0 / 0, 0, 0, 0, 0, 0, 0, -1 } }
  for _ = 1, 20 do
    frame = state:update(0.5, false)
  end
  expect.truthy(frame.spectrum[1] >= 0 and frame.spectrum[1] < 1e-6, 'non-finite input releases to zero')
  expect.truthy(frame.spectrum[8] >= 0 and frame.spectrum[8] < 1e-6, 'negative input releases to zero')
end)

test('source changes crossfade the spectrum with the coarse bands', function()
  local state = new { response = 1, attackDuration = 0 }
  state:setFeatures { bass = 0, mid = 0, treble = 0, spectrum = { 1, 1, 1, 1, 0, 0, 0, 0 } }
  state:update(0.01, false)
  state:sourceChanged()
  state:setFeatures { bass = 0, mid = 0, treble = 0, spectrum = { 0, 0, 0, 0, 1, 1, 1, 1 } }
  local half = state:update(0.6, false)
  expect.near(half.spectrum[1], 0.5, 1e-8, 'old band halfway out')
  expect.near(half.spectrum[8], 0.5, 1e-8, 'new band halfway in')
end)

return test
