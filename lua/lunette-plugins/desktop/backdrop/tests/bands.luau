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

test('band overflow retains the newest waves without evicting other bands', function()
  for _, band in { 'bass', 'mid', 'treble' } :: { model.Band } do
    for _, batchSize in { 1, 12 } do
      local state = new()
      for _, other in { 'bass', 'mid', 'treble' } :: { model.Band } do
        if other ~= band then
          state:setFeatures(ZERO, { { strength = 1, band = other } })
        end
      end
      local onsets: { model.Onset } = {}
      for index = 1, 12 do
        onsets[#onsets + 1] = { strength = 1, band = band, position = index / 12 }
        if #onsets == batchSize then
          state:setFeatures(ZERO, onsets)
          table.clear(onsets)
        end
      end
      for _, other in { 'bass', 'mid', 'treble' } :: { model.Band } do
        expect.equal(count(state.waves, other), if other == band then model.wavePools[band] else 1, 'independent pool')
      end
      expect.equal(state.onsetGap, 'capacity', 'overflow is explicit')
      local discarded = 12 - model.wavePools[band]
      expect.equal(state.discardedHops, discarded, 'each eviction counted')
      local first
      for _, wave in state.waves do
        if wave.band == band then
          first = wave
          break
        end
      end
      expect.equal(first.position, (13 - model.wavePools[band]) / 12, 'oldest surviving onset')
      expect.equal(state.waves[#state.waves].position, 1, 'newest onset retained')
      state:setFeatures(ZERO, {})
      expect.equal(#state.waves, 2 + model.wavePools[band], 'empty publication retains waves')
      expect.equal(state.discardedHops, discarded, 'empty publication does not repeat discard')
    end
  end
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
  local frame = state:update(0.12, false)
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

return test
