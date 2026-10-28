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

test('packing preserves every live prefix and source order within each band', function()
  local orders = {
    { 'bass', 'mid', 'treble' },
    { 'treble', 'mid', 'bass' },
    { 'mid', 'treble', 'bass', 'treble', 'mid', 'bass', 'bass' },
    { 'bass' },
    { 'mid' },
    { 'treble' },
  }
  for _, order in orders do
    for count = 0, model.MAX_WAVES do
      local source = {}
      for index = 1, count do
        source[index] = {
          age = index / 100,
          strength = 0.9 - index / 100,
          position = index / (model.MAX_WAVES + 1),
          band = order[(index - 1) % #order + 1],
          lifetime = 1.2,
          frequency = index / model.MAX_WAVES,
        }
      end
      local original = table.clone(source)
      local snapshots = {}
      for index, value in source do
        snapshots[index] = table.clone(value)
      end
      local packed, details, ends, live = uniforms.prepare(source, 0.7)
      testing.expect.equal(live, count, 'the count comes from the live prefix')
      testing.expect.equal(#packed, model.MAX_WAVES, 'all wave slots are sent')
      testing.expect.equal(#details, model.MAX_WAVES, 'all detail slots are sent')
      local slot = 0
      for band, name in { 'bass', 'mid', 'treble' } do
        for _, value in original do
          if value.band == name then
            slot += 1
            local expected =
              { value.age, value.strength * (1 - value.age / value.lifetime) * 0.7, value.position, band }
            local prepared = uniforms.detail(value)
            for lane = 1, 4 do
              testing.expect.equal(packed[slot][lane], expected[lane], 'stable band order preserves each row')
              testing.expect.equal(details[slot][lane], prepared[lane], 'prepared detail follows its wave')
            end
          end
        end
        testing.expect.equal(ends[band], slot, 'each cumulative end follows the actual packed band')
      end
      testing.expect.equal(ends[4], 0, 'the unused uniform lane is cleared')
      for index = count + 1, model.MAX_WAVES do
        for lane = 1, 4 do
          testing.expect.equal(packed[index][lane], 0, 'inactive wave slots are cleared')
          testing.expect.equal(details[index][lane], 0, 'inactive detail slots are cleared')
        end
      end
      testing.expect.equal(#source, count, 'packing does not resize the model waves')
      for index, value in source do
        testing.expect.equal(value, original[index], 'packing does not reorder or replace model waves')
        for field, expected in snapshots[index] do
          testing.expect.equal(value[field], expected, 'packing does not change a model wave')
        end
      end
    end
  end
end)

return test
