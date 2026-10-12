local testing = require '@testing'
local expect = testing.expect
local config = require '../config'
local geometry = require '../geometry'

local test = testing.suite()

test('quality bounds finite indexed geometry and full directional coverage', function()
  local segments = { low = 64, standard = 128, high = 192 }
  local vertical = { low = 6, standard = 8, high = 12 }
  for _, quality in { 'low', 'standard', 'high' } do
    local data = geometry.build(config.schema.parse { quality = quality })
    expect.equal(#data.sky.vertices, (segments[quality] + 1) * 25, 'fixed sky vertex count')
    expect.equal(#data.curtain.vertices, (segments[quality] + 1) * (vertical[quality] + 1), 'fixed curtain count')
    expect.equal(#data.curtain.indices, segments[quality] * vertical[quality] * 6, 'fixed curtain index count')
    for _, surface in { data.sky, data.curtain } do
      for _, vertex in surface.vertices do
        expect.equal(#vertex, 8, 'default attributes')
        for _, value in vertex do
          expect.truthy(value == value and math.abs(value) < math.huge, 'finite vertex')
        end
      end
      for _, index in surface.indices do
        expect.truthy(index % 1 == 0 and index >= 1 and index <= #surface.vertices, 'valid index')
      end
    end
    local directions = { false, false, false, false, false, false }
    for _, vertex in data.sky.vertices do
      for axis = 1, 3 do
        if vertex[axis] < -20 then
          directions[axis * 2 - 1] = true
        elseif vertex[axis] > 20 then
          directions[axis * 2] = true
        end
      end
    end
    for _, covered in directions do
      expect.equal(covered, true, 'all directions covered')
    end
  end
end)

test('schema rejects nonfinite values unknown fields and unbounded quality or palettes', function()
  for _, given in
    {
      { motion = math.huge },
      { response = 0 / 0 },
      { distance = 0 },
      { quality = 'unbounded' },
      { palette = { low = { 0.5, 0.5 } } },
      { palette = { high = { 0.5, 2, 0.5 } } },
      { misspelled = true },
    }
  do
    expect.equal(pcall(config.schema.parse, given), false, 'invalid settings rejected')
  end
end)

return test
