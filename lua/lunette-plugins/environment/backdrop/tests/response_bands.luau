local testing = require '@testing'
local expect = testing.expect
local support = require './support/response'
local model = require '../private/rendering/model'
local responseChild = require '../private/response-child'
local analysis = require '@lunette-contracts/audio-analysis'

local test = testing.suite()
local SYSTEM: analysis.Source = { kind = 'system' }

local function waves(env: typeof(support.boot()), band: model.Band): { model.Wave }
  local found = {}
  for _, wave in env.model.waves do
    if wave.band == band then
      table.insert(found, wave)
    end
  end
  return found
end

test('waves land near the facing direction, each band scattered by its own width', function()
  local env = support.boot()
  env.update(1.2, false)
  local hops = {}
  for index = 1, 8 do
    local hop = table.clone(support.hop(1, 4096 + index * 2048, 1, 'treble'))
    hop.midOnset = 1
    if index <= 4 then
      hop.bassOnset = 1
    end
    hops[index] = hop
  end
  env.publish(SYSTEM, 1, 4096 + 8 * 2048, hops)
  env.update(0, false)
  local widths = { bass = 0.05, mid = 0.08, treble = 0.16 }
  local distinct = {}
  for _, wave in env.model.waves do
    local offset = math.abs((wave.position - 0.5 + 0.5) % 1 - 0.5)
    expect.truthy(offset <= widths[wave.band] / 2, wave.band .. ' onset within its scatter of -z')
    distinct[wave.position] = true
  end
  local spread = 0
  for _ in distinct do
    spread += 1
  end
  expect.equal(#env.model.waves, 20, 'four bass, eight mid, and eight treble waves')
  expect.equal(spread, 20, 'no two onsets, even of different bands in one hop, share a longitude')
  env.session:close()
end)

test('the anchor snaps to a twelfth of a turn and holds until the view passes the sector edge', function()
  local sector = responseChild.sector
  expect.equal(sector(nil, nil), nil, 'without a facing or an anchor there is none')
  expect.equal(sector(nil, 0.51), 6 / 12, 'the nearest sector centre')
  expect.equal(sector(nil, 0.99), 0, 'sectors wrap at a full turn')
  expect.equal(sector(6 / 12, 0.54), 6 / 12, 'past the half-width but within the hold the anchor stays')
  expect.equal(sector(6 / 12, nil), 6 / 12, 'an unavailable facing keeps the anchor')
  expect.equal(sector(6 / 12, 0.56), 7 / 12, 'beyond the hold the anchor moves')
  expect.equal(sector(0, 0.97), 0, 'the hold measures around the wrap')
  expect.equal(sector(0, 0 / 0), 0, 'a non-finite facing keeps the anchor')
end)

test('one transient split across adjacent hops makes one wave at its strongest', function()
  local env = support.boot()
  env.update(1.2, false)
  local both = table.clone(support.hop(1, 4608, 1, 'treble'))
  both.bassOnset = 0.6
  env.publish(SYSTEM, 1, 5120, { support.hop(1, 4096, 0.4, 'treble'), both })
  env.update(0, false)
  expect.equal(#waves(env, 'treble'), 1, 'adjacent treble hops are one transient')
  -- The source crossfade weights a hop by its sample age, (1.2 - age) / 1.2 here.
  local weighted = (1.2 - 512 / 48000) / 1.2
  expect.near(waves(env, 'treble')[1].strength, weighted, 1e-12, 'the wave keeps the stronger hop')
  expect.near(waves(env, 'treble')[1].age, 1024 / 48000, 1e-12, 'the wave starts at the earlier hop')
  expect.equal(#waves(env, 'bass'), 1, 'another band at the same time stays separate')
  env.publish(SYSTEM, 1, 5632, { support.hop(1, 5120, 1, 'treble') })
  env.update(0, false)
  expect.equal(#waves(env, 'treble'), 1, 'a continuation in the next publication adds no wave')
  env.publish(SYSTEM, 1, 9216, { support.hop(1, 9216, 1, 'treble') })
  env.update(0, false)
  expect.equal(#waves(env, 'treble'), 2, 'a later transient is a new wave')
  env.publish(SYSTEM, 1, 9728, { support.hop(1, 9728, 1, 'treble') }, nil, nil, true)
  env.update(0, false)
  expect.equal(#waves(env, 'treble'), 1, 'after a gap the next onset is a new wave, not a continuation')
  env.session:close()
end)

test('excess onsets are bounded per band within one publication', function()
  local env = support.boot()
  env.update(1.2, false)
  env.publish(SYSTEM, 1, 0, {})
  env.update(0, false)
  local hops = {}
  for index = 1, 12 do
    hops[index] = support.hop(1, index * 2048, 1, 'treble')
  end
  table.insert(hops, support.hop(1, 13 * 2048, 1, 'bass'))
  env.publish(SYSTEM, 1, 13 * 2048, hops)
  env.update(0, false)
  expect.equal(#waves(env, 'treble'), model.wavePools.treble, 'treble bounded by its pool')
  expect.equal(#waves(env, 'bass'), 1, 'bass survives a treble overflow')
  expect.equal(env.model.discardedHops, 12 - model.wavePools.treble, 'treble overflow counted')
  expect.equal(env.model.onsetGap, 'capacity', 'overflow is explicit')
  expect.near(waves(env, 'treble')[1].age, 12 * 2048 / 48000, 1e-8, 'the earliest active onset keeps its sample age')
  env.update(0, false)
  expect.equal(env.model.discardedHops, 12 - model.wavePools.treble, 'repeated publication does not repeat discard')
  env.session:close()
end)

test('the spectrum uses a fixed calibration that preserves silence', function()
  local env = support.boot()
  env.update(1.2, false)
  env.publish(SYSTEM, 1, 4096, {}, nil, nil, nil, { 0, 0.0001, 0.01, 1, 0 / 0, -1, 0.0004, 0.0001 })
  env.update(0, false)
  local spectrum = env.model.target.spectrum
  expect.equal(spectrum[1], 0, 'silence stays silent')
  expect.near(spectrum[2], 3 / 53, 1e-12, 'low bass gain')
  expect.near(spectrum[3], 1 / 3, 1e-12, 'bass gain')
  expect.near(spectrum[4], 11 / 13, 1e-12, 'full scale retains headroom')
  expect.equal(spectrum[5], 0, 'non-finite power is silent')
  expect.equal(spectrum[6], 0, 'negative power is silent')
  expect.near(spectrum[7], 13 / 63, 1e-12, 'treble lift')
  expect.near(spectrum[8], 13 / 113, 1e-12, 'air lift')
  env.session:close()
end)

test('the renderer receives the spectrum and band-tagged waves', function()
  local env = support.boot()
  env.update(1.2, false)
  local hop = table.clone(support.hop(1, 4096, 0))
  hop.bassOnset, hop.midOnset, hop.trebleOnset = 0.9, 0.5, 0.7
  env.publish(SYSTEM, 1, 4096, { hop }, nil, nil, nil, { 0.01, 0, 0, 0, 0, 0, 0, 0.01 })
  env.update(0, false)
  expect.equal(#env.model.waves, 3, 'one wave per band')
  expect.equal(waves(env, 'bass')[1].strength, 0.9, 'bass strength')
  expect.equal(waves(env, 'mid')[1].strength, 0.5, 'mid strength')
  expect.equal(waves(env, 'treble')[1].strength, 0.7, 'treble strength')
  -- The base frame updates before the response child, so the drawn frame trails the delivery by one update.
  env.update(0.1, false)
  env.session:draw()
  local spectrum = env.uniforms.backdropSpectrum :: { { number } }
  expect.equal(#spectrum, 2, 'two vec4 groups')
  expect.truthy(spectrum[1][1] > 0 and spectrum[2][4] > 0, 'lit bands reach the shader')
  expect.equal(spectrum[1][2], 0, 'unlit band')
  local sent = env.uniforms.backdropWaves :: { { number } }
  expect.equal(#sent, model.MAX_WAVES, 'every pool slot is sent')
  local bands = {}
  for _, wave in sent do
    if wave[2] > 0 then
      bands[wave[4]] = true
    end
  end
  expect.truthy(bands[1] and bands[2] and bands[3], 'each band index reaches the shader')
  for _, colour in { 'backdropBass', 'backdropMid', 'backdropTreble', 'backdropFocus' } do
    expect.truthy(env.uniforms[colour] ~= nil, colour .. ' sent')
  end
  env.session:close()
end)

return test
