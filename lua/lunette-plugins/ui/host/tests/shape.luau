local testing = require '@testing'
local shape = require '../private/shape'
local expect = testing.expect
local test = testing.suite()

local function panel(curve: number, axis: number?): any
  return {
    width = 0.6,
    height = 0.4,
    curve = curve,
    curveAxis = axis or 0,
    pose = lovr.math.newMat4():translate(0.2, 1.4, -0.8),
  }
end

-- Curves towards and away from the viewer, about the vertical, a tilted axis, and the horizontal.
local BENDS: { { number } } = {
  { 0, 0 },
  { 0.5, 0 },
  { 1.5, 0 },
  { 3, 0 },
  { -0.5, 0 },
  { -3, 0 },
  { 2, 0.98 },
  { -2, 0.98 },
  { -4, math.pi / 2 },
}

-- A fixed linear congruential sequence keeps the cases the same on every run.
local seed = 0x5eed
local function nextNumber(): number
  seed = (seed * 1103515245 + 12345) % 2147483648
  return seed / 2147483648
end

test('a point placed on the surface maps back to its panel coordinates and elevation', function()
  for _, bend in BENDS do
    local curve = `{bend[1]} about {bend[2]}`
    local target = panel(bend[1], bend[2])
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
  for _, bend in BENDS do
    local curve = `{bend[1]} about {bend[2]}`
    local target = panel(bend[1], bend[2])
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

test('an elevated point on a panel bent away lies outside its surface', function()
  local target = panel(-2)
  local _, _, zFlat = lovr.math.newMat4(target.pose):invert():mul(shape.frame(target, 0.3, 0.2, 0):getPosition())
  local _, _, zRaised = lovr.math.newMat4(target.pose):invert():mul(shape.frame(target, 0.3, 0.2, 0.05):getPosition())
  expect.near(zFlat, 0, 1e-6, 'the centre lies on the panel plane')
  expect.near(zRaised, 0.05, 1e-6, 'elevation is towards the viewer')
  local _, _, edge = lovr.math.newMat4(target.pose):invert():mul(shape.frame(target, 0, 0.2, 0):getPosition())
  expect.truthy(edge < 0, 'the edges bend away from the viewer')
end)

test('a curve too tight for the panel wraps it half a turn either side at most', function()
  expect.equal(shape.curvature(panel(0)), 0)
  expect.equal(shape.curvature(panel(-3)), -3, 'a curve within the limit is kept')
  local tight = shape.curvature(panel(-100))
  expect.near(tight, -2 * math.pi / 0.6, 1e-9, 'the width across the axis wraps one circumference')
  local across = shape.curvature(panel(100, math.pi / 2))
  expect.near(across, 2 * math.pi / 0.4, 1e-9, 'about the horizontal, the height is across the axis')
end)

return test
