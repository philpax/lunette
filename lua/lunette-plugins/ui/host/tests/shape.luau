local testing = require '@testing'
local shape = require '../private/shape'
local expect = testing.expect
local test = testing.suite()

local function panel(curve: number): any
  return { width = 0.6, height = 0.4, curve = curve, pose = lovr.math.newMat4():translate(0.2, 1.4, -0.8) }
end

-- A fixed linear congruential sequence keeps the cases the same on every run.
local seed = 0x5eed
local function nextNumber(): number
  seed = (seed * 1103515245 + 12345) % 2147483648
  return seed / 2147483648
end

test('a point placed on the surface maps back to its panel coordinates and elevation', function()
  for _, curve in { 0, 0.5, 1.5, 3 } do
    local target = panel(curve)
    local inverse = lovr.math.newMat4(target.pose):invert()
    for _ = 1, 50 do
      local u, v, elevation = nextNumber() * target.width, nextNumber() * target.height, nextNumber() * 0.05
      local x, y, z = shape.frame(target, u, v, elevation):getPosition()
      local mu, mv, me = shape.toPanel(target, inverse:mul(x, y, z))
      expect.near(mu, u, 1e-5, `curve {curve}: u`)
      expect.near(mv, v, 1e-5, `curve {curve}: v`)
      expect.near(me, elevation, 1e-5, `curve {curve}: elevation`)
    end
  end
end)

test('a ray towards a point on the surface hits it there', function()
  for _, curve in { 0, 0.8, 2 } do
    local target = panel(curve)
    for _ = 1, 50 do
      local u, v = nextNumber() * target.width, nextNumber() * target.height
      local surface = vector.pack(shape.frame(target, u, v, 0):getPosition())
      local origin = vector.pack(0.2 + (nextNumber() - 0.5) * 0.2, 1.4, 0.2)
      local localOrigin, localDirection = shape.localRay(target, origin, surface - origin)
      local hu, hv, distance = shape.ray(target, localOrigin, localDirection, true)
      assert(hu and hv and distance, `curve {curve}: the ray hits`)
      expect.near(hu, u, 1e-4, `curve {curve}: u`)
      expect.near(hv, v, 1e-4, `curve {curve}: v`)
      expect.near(distance, vector.magnitude(surface - origin), 1e-4, `curve {curve}: distance`)
    end
  end
end)

test('a ray beside a panel misses, and an unbounded projection still reports it', function()
  local target = panel(1)
  local origin = vector.pack(5, 1.4, 0.2)
  local localOrigin, localDirection = shape.localRay(target, origin, vector.pack(0, 0, -1))
  expect.equal(shape.ray(target, localOrigin, localDirection, true), nil)
end)

return test
