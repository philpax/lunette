-- Both panel families map a ray through the shared curved-surface library, so a common case agrees.

local testing = require '@testing'
local expect = testing.expect
local nativeShape = require '@lunette-plugins/panels/service/private/shape'
local hostShape = require '@lunette-plugins/ui/host/private/shape'
local curved = require '@lunette-plugins/graphics/curved-surface'

local test = testing.suite()

test('a native hit and a toolkit hit agree on one curved panel', function()
  local width, height = 2, 1
  local pose = lovr.math.newMat4():translate(0, 1, -2)
  for _, axis in { 0, math.pi / 4, math.pi / 2 } do
    for _, curve in { 0.5, -0.5 } do
      local nativeTarget = {
        pose = pose,
        width = width,
        height = height,
        pixelWidth = 1000,
        pixelHeight = 500,
        curve = curve,
        curveAxis = axis,
      }
      local hostTarget: any = {
        pose = pose,
        width = width,
        height = height,
        curve = curve,
        curveAxis = axis,
        scale = 1,
      }
      local surface = curved.surface(width, height, curve, axis)
      for step = 1, 7 do
        local u = width * step / 8
        local x, y, z, nx, ny, nz = curved.point(surface, u, height / 2)
        local localOrigin = vector.pack(x + nx, y + ny, z + nz)
        local localDirection = vector.pack(-nx, -ny, -nz)
        local worldOrigin = pose:mul(localOrigin)
        local wx, wy, wz = localDirection:unpack()
        local worldDirection = vector.pack(pose:mul(wx, wy, wz, 0))
        local pixelX, pixelY = nativeShape.hit(nativeTarget, worldOrigin, worldDirection)
        local hostU, hostV = hostShape.ray(hostTarget, localOrigin, localDirection, true)
        local where = `axis {axis}, curve {curve}, u {u}`
        expect.truthy(pixelX and hostU, where .. ': both hit')
        expect.near(pixelX, hostU / width * 1000, 1e-4, where .. ': the horizontal coordinate')
        expect.near(pixelY, hostV / height * 500, 1e-4, where .. ': the vertical coordinate')
      end
    end
  end
end)

return test
