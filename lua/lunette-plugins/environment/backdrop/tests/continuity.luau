local testing = require '@testing'
local expect = testing.expect
local config = require '../config'
local model = require '../private/rendering/model'
local support = require './support/response'

local test = testing.suite()
local ZERO: model.Features = { bass = 0, mid = 0, treble = 0 }
local SYSTEM = { kind = 'system' }

local function count(state: model.State, band: model.Band): number
  local total = 0
  for _, wave in state.waves do
    total += if wave.band == band then 1 else 0
  end
  return total
end

test('active waves retain identity until expiry and released slots accept new beats', function()
  for _, band in { 'bass', 'mid', 'treble' } :: { model.Band } do
    local state = model.new(config.schema.parse {})
    for index = 1, model.wavePools[band] do
      state:setFeatures(ZERO, { { band = band, strength = 0.5, position = index / 30, frequency = index / 30 } })
    end
    local retained = table.clone(state.waves)
    state:update(model.waveLifetimes[band] * 0.25, false)
    for _ = 1, 10 do
      state:setFeatures(ZERO, { { band = band, strength = 1, position = 0.9 } })
    end
    expect.equal(state.discardedHops, 10, 'new beats are skipped explicitly')
    for index, wave in retained do
      expect.equal(state.waves[index], wave, 'an active wave is not replaced')
      expect.near(wave.age, model.waveLifetimes[band] * 0.25, 1e-12, 'age remains continuous')
      expect.equal(wave.position, index / 30, 'position does not jump')
      expect.equal(wave.strength, 0.5, 'new beats do not change the active strength')
    end
    state:update(model.waveLifetimes[band] * 0.76, false)
    expect.equal(count(state, band), 0, 'the original waves finish naturally')
    state:setFeatures(ZERO, { { band = band, strength = 1, position = 0.9 } })
    expect.equal(count(state, band), 1, 'an expired slot accepts a new beat')
    expect.equal(state.waves[1].position, 0.9, 'the new beat uses its own position')
    expect.equal(state.discardedHops, 10, 'acceptance adds no discard')
  end
end)

test('zero-strength and expired onsets do not reserve slots or evict valid waves', function()
  local state = model.new(config.schema.parse {})
  local onsets: { model.Onset } = { { band = 'bass', strength = 0.5, position = 0.1 } }
  for _ = 1, 20 do
    table.insert(onsets, { band = 'bass', strength = 0 })
    table.insert(onsets, { band = 'bass', strength = 1, age = model.waveLifetimes.bass })
  end
  table.insert(onsets, { band = 'bass', strength = 1, position = 0.2 })
  state:setFeatures(ZERO, onsets)
  expect.equal(count(state, 'bass'), 2, 'only two valid onsets fill slots')
  expect.equal(state.waves[1].position, 0.1, 'the first valid onset survives the invalid tail')
  expect.equal(state.discardedHops, 0, 'invalid onsets are not capacity losses')
end)

test('publication overflow preserves moving waves in every band across deliveries', function()
  local env = support.boot()
  env.update(1.2, false)
  local both = table.clone(support.hop(1, 2048, 0.5, 'bass'))
  both.midOnset = 0.5
  env.publish(SYSTEM, 1, 2048, { both })
  env.update(0, false)
  local bass, mid = env.model.waves[1], env.model.waves[2]
  local hops = {}
  for index = 1, 12 do
    hops[index] = support.hop(1, 2048 + index * 2048, 1, 'treble')
  end
  env.publish(SYSTEM, 1, 13 * 2048, hops)
  env.update(0.1, false)
  expect.equal(env.model.waves[1], bass, 'treble overflow does not clear a moving bass wave')
  expect.equal(env.model.waves[2], mid, 'treble overflow does not clear a moving mid wave')
  expect.near(bass.age, 0.1, 1e-12, 'a retained wave continues moving')
  local treble = env.model.waves[3]
  env.publish(SYSTEM, 1, 14 * 2048, { support.hop(1, 14 * 2048, 1, 'treble') })
  env.update(0, false)
  expect.equal(env.model.waves[3], treble, 'the next delivery cannot replace an active same-band wave')
  expect.equal(env.model.discardedHops, 5, 'four overflow onsets and one later onset are counted')
  expect.equal(env.model.onsetGap, 'capacity', 'visual capacity loss remains explicit')
  env.update(0, false)
  expect.equal(env.model.discardedHops, 5, 'a retained publication is not processed twice')
  env.publish(SYSTEM, 2, 2048, { support.hop(2, 2048, 1, 'bass') }, nil, nil, true)
  env.update(0, false)
  expect.equal(#env.model.waves, 1, 'a real audio discontinuity still resets wave history')
  expect.equal(env.model.onsetGap, 'publication', 'audio history loss stays distinct from capacity')
  env.session:close()
end)

test('an audio history reset remains explicit even when its new onset batch overflows', function()
  local state = model.new(config.schema.parse {})
  state:setFeatures(ZERO, { { band = 'mid', strength = 1 } })
  local onsets: { model.Onset } = {}
  for index = 1, 12 do
    onsets[index] = { band = 'bass', strength = 1, position = index / 30 }
  end
  state:setFeatures(ZERO, onsets, { gap = 'publication' })
  expect.equal(count(state, 'mid'), 0, 'the actual reset clears old history')
  expect.equal(count(state, 'bass'), model.wavePools.bass, 'fresh waves fill the available slots')
  expect.equal(state.onsetGap, 'publication', 'the audio reset takes precedence over capacity loss')
  expect.equal(state.discardedHops, 12 - model.wavePools.bass, 'capacity loss is still counted')
end)

return test
