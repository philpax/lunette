-- Generic shader and readback baseline; production pixel fixtures use the same runtime.

local testing = require '@testing'
local render = require './support/render'
local test = testing.suite()

local function pixel(image: Image, x: number, y: number, expected: { number })
  local channels = { image:getPixel(x, y) }
  for index, value in expected do
    testing.expect.near(channels[index], value, 1 / 255, 'pixel channel ' .. index)
  end
end

test('a shader rasterizes asymmetric colors into an offscreen texture', function()
  local texture, pass = render.baseline()
  local image = render.read(texture, pass)
  testing.expect.equal(image:getWidth(), 16)
  testing.expect.equal(image:getHeight(), 8)
  for y = 0, 7 do
    for x = 0, 15 do
      pixel(image, x, y, if x < 8 then { 0.25, 0.5, 0.75, 1 } else { 0.75, 0.25, 0.5, 1 })
    end
  end
end)

return test
