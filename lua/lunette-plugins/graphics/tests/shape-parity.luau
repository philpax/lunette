-- Both panel families map a ray through the shared curved-surface library, so a common case agrees.

local testing = require '@testing'
local expect = testing.expect
local nativeShape = require '@lunette-plugins/panels/service/private/shape'
local hostShape = require '@lunette-plugins/ui/host/private/shape'

local test = testing.suite()

test('a native hit and a toolkit hit agree on one curved panel', function()
  local width, height, curve = 2, 1, 0.5
  local pose = lovr.math.newMat4():translate(0, 1, -2)
  local nativeTarget = {
    pose = pose,
    width = width,
    height = height,
    pixelWidth = 1000,
    pixelHeight = 500,
    curve = curve,
  }
  local hostTarget: any = {
    pose = pose,
    width = width,
    height = height,
    curve = curve,
    curveAxis = 0,
    scale = 1,
  }
  local half = math.min(width * curve / 2, math.pi)
  for step = -4, 4 do
    local angle = half * step / 4.5
    local direction = vector.pack(math.sin(angle), 0, -math.cos(angle))
    local localOrigin = vector.pack(0, 0, 2)
    local pixelX, pixelY = nativeShape.hit(nativeTarget, pose:mul(localOrigin), direction)
    local u, v = hostShape.ray(hostTarget, localOrigin, direction, true)
    expect.truthy(pixelX and u, `angle {angle}: both hit`)
    expect.near(pixelX, u / width * 1000, 1e-9, `angle {angle}: the horizontal coordinate`)
    expect.near(pixelY, v / height * 500, 1e-9, `angle {angle}: the vertical coordinate`)
  end
end)

return test
