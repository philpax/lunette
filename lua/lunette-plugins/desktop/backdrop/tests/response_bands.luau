local testing = require '@testing'
local expect = testing.expect
local support = require './support/response'
local model = require '../model'
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

test('one hop delivers a wave for each band with an onset', function()
  local env = support.boot()
  env.update(1.2, false)
  local hop = table.clone(support.hop(1, 4096, 0))
  hop.bassOnset, hop.midOnset, hop.trebleOnset = 0.9, 0.5, 0.7
  env.publish(SYSTEM, 1, 4096, { hop })
  env.update(0, false)
  expect.equal(#env.model.waves, 3, 'three band waves')
  expect.equal(waves(env, 'bass')[1].strength, 0.9, 'bass strength')
  expect.equal(waves(env, 'mid')[1].strength, 0.5, 'mid strength')
  expect.equal(waves(env, 'treble')[1].strength, 0.7, 'treble strength')
  env.session:close()
end)

test('without a panel direction waves face forward and treble glints scatter around it', function()
  local env = support.boot()
  env.update(1.2, false)
  local hops = {}
  for index = 1, 6 do
    hops[index] = support.hop(1, 4096 + index * 512, 1, 'treble')
  end
  table.insert(hops, support.hop(1, 4096 + 7 * 512, 1, 'bass'))
  env.publish(SYSTEM, 1, 4096 + 7 * 512, hops)
  env.update(0, false)
  expect.equal(waves(env, 'bass')[1].position, 0.5, 'bass heave faces -z')
  local distinct = {}
  for _, wave in waves(env, 'treble') do
    expect.truthy(math.abs(wave.position - 0.5) <= 0.125, 'glint within a quarter turn of the anchor')
    distinct[wave.position] = true
  end
  local spread = 0
  for _ in distinct do
    spread += 1
  end
  expect.truthy(spread > 1, 'glints do not stack at one longitude')
  env.session:close()
end)

test('excess onsets are bounded per band within one publication', function()
  local env = support.boot()
  env.update(1.2, false)
  local hops = {}
  for index = 1, 12 do
    hops[index] = support.hop(1, index * 512, 1, 'treble')
  end
  table.insert(hops, support.hop(1, 13 * 512, 1, 'bass'))
  env.publish(SYSTEM, 1, 13 * 512, hops)
  env.update(0, false)
  expect.equal(#waves(env, 'treble'), model.wavePools.treble, 'treble bounded by its pool')
  expect.equal(#waves(env, 'bass'), 1, 'bass survives a treble overflow')
  expect.equal(env.model.discardedHops, 12 - model.wavePools.treble, 'treble overflow counted')
  expect.equal(env.model.onsetGap, 'capacity', 'overflow is explicit')
  env.session:close()
end)

test('the spectrum uses a fixed calibration that preserves silence', function()
  local env = support.boot()
  env.update(1.2, false)
  env.publish(SYSTEM, 1, 4096, {}, nil, nil, nil, { 0, 0.0001, 0.01, 1, 0 / 0, -1, 0.0004, 0.0001 })
  env.update(0, false)
  local spectrum = env.model.target.spectrum
  expect.equal(spectrum[1], 0, 'silence stays silent')
  expect.near(spectrum[2], 0.07, 1e-12, 'sub-bass gain')
  expect.near(spectrum[3], 0.7, 1e-12, 'bass gain')
  expect.equal(spectrum[4], 1, 'full scale clamps')
  expect.equal(spectrum[5], 0, 'non-finite power is silent')
  expect.equal(spectrum[6], 0, 'negative power is silent')
  expect.near(spectrum[7], 0.24, 1e-12, 'treble lift')
  expect.near(spectrum[8], 0.14, 1e-12, 'air lift')
  env.session:close()
end)

test('the renderer receives the spectrum and band-tagged waves', function()
  local env = support.boot()
  env.update(1.2, false)
  local hop = table.clone(support.hop(1, 4096, 0))
  hop.bassOnset, hop.trebleOnset = 1, 1
  env.publish(SYSTEM, 1, 4096, { hop }, nil, nil, nil, { 0.01, 0, 0, 0, 0, 0, 0, 0.01 })
  env.update(0.1, false)
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
  expect.truthy(bands[1] and bands[3] and not bands[2], 'bass and treble indices reach the shader')
  for _, colour in { 'backdropBass', 'backdropMid', 'backdropTreble', 'backdropFocus' } do
    expect.truthy(env.uniforms[colour] ~= nil, colour .. ' sent')
  end
  env.session:close()
end)

return test
