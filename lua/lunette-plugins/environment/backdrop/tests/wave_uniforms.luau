local testing = require '@testing'
local model = require '../private/rendering/model'
local uniforms = require '../private/rendering/wave-uniforms'
local test = testing.suite()

local function wave(band: model.Band, age: number, frequency: number): model.Wave
  return { age = age, frequency = frequency, band = band, strength = 1, position = 0.5, lifetime = 1.2 }
end

test('onset preparation preserves travel and decay bounds across each lifetime', function()
  for _, band: model.Band in { 'bass', 'mid', 'treble' } do
    local previousTravel, previousDecay, previousFlash = 0, 1, 1
    for step = 0, 120 do
      local age = step * model.waveLifetimes[band] / 120
      local value = uniforms.detail(wave(band, age, 0.5))
      testing.expect.equal(value[1], 0.5, 'frequency remains independent of age')
      testing.expect.truthy(value[2] >= previousTravel, 'the wavefront never travels backward')
      testing.expect.truthy(value[3] >= 0 and value[3] <= 1, 'band decay stays bounded')
      testing.expect.truthy(value[4] <= previousFlash and value[4] > 0, 'the initial flash decays')
      if band ~= 'treble' or age >= 0.09 then
        testing.expect.truthy(value[3] <= previousDecay, 'the settled onset decays')
      end
      previousTravel, previousDecay, previousFlash = value[2], value[3], value[4]
    end
  end
end)

test('new treble onsets rise from zero and frequency bounds control travel', function()
  testing.expect.equal(uniforms.detail(wave('treble', 0, 0.5))[3], 0, 'treble starts dark')
  for _, band: model.Band in { 'bass', 'mid', 'treble' } do
    local low, high = uniforms.detail(wave(band, 0.2, 0)), uniforms.detail(wave(band, 0.2, 1))
    testing.expect.truthy(low[2] < high[2], 'higher detail travels faster')
    testing.expect.equal(low[3], high[3], 'frequency does not change decay')
    testing.expect.equal(low[4], high[4], 'frequency does not change the initial flash')
    local below, above = uniforms.detail(wave(band, 0.2, -1)), uniforms.detail(wave(band, 0.2, 2))
    for lane = 1, 4 do
      testing.expect.equal(below[lane], low[lane], 'lower detail is clamped')
      testing.expect.equal(above[lane], high[lane], 'upper detail is clamped')
    end
  end
end)

return test
