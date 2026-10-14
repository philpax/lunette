local testing = require '@testing'
local expect = testing.expect

local quad = require '@lunette-contracts/quad'
local shape = require '@lunette-plugins/panels/shape'
local geometry = require '@lunette-plugins/graphics/rounded-geometry'

local test = testing.suite()

type Panel = {
  pose: Mat4,
  width: number,
  height: number,
  pixelWidth: number,
  pixelHeight: number,
  curve: number,
  polygon: { geometry.Point }?,
  backFace: boolean?,
}

local WIDTH, HEIGHT = 2, 1
local PIXELS_WIDE, PIXELS_HIGH = 1000, 500

local function panel(curve: number, pose: Mat4?): Panel
  return {
    pose = pose or lovr.math.newMat4():translate(0, 1, -2),
    width = WIDTH,
    height = HEIGHT,
    pixelWidth = PIXELS_WIDE,
    pixelHeight = PIXELS_HIGH,
    curve = curve,
  }
end

test('a flat panel picks as a quad, except outside its rounded corners', function()
  local random = lovr.math.newRandomGenerator(20261002)
  for case = 1, 20 do
    local origin = vector.pack(random:random() - 0.5, 1 + random:random() - 0.5, random:random())
    local direction = vector.pack(random:random() - 0.5, random:random() - 0.5, -1)
    local x, y, distance = shape.hit(panel(0), origin, direction)
    local qx, qy, qd = quad.hit(panel(0), origin, direction)
    expect.truthy(x == qx and y == qy and distance == qd, 'case ' .. case)
  end
  local rounded = panel(0)
  rounded.polygon = geometry.perimeter({ x = 0, y = 0, width = WIDTH, height = HEIGHT }, geometry.uniform(0.2))
  local corner = vector.pack(0.01 - WIDTH / 2, 1 + HEIGHT / 2 - 0.01, 0)
  expect.truthy(quad.hit(rounded, corner, vector.pack(0, 0, -1)), 'the corner lies inside the quad')
  expect.falsy(shape.hit(rounded, corner, vector.pack(0, 0, -1)), 'the corner outside the rounding misses')
end)

test('a curved panel picks on its arc, follows its pose, and misses past either end', function()
  local curve = 0.5
  local half = shape.halfAngle(WIDTH, curve)
  local origin = vector.pack(0, 1, 0)
  for step = -4, 4 do
    local angle = half * step / 4.5
    local x, y, distance = shape.hit(panel(curve), origin, vector.pack(math.sin(angle), 0, -math.cos(angle)))
    expect.near(distance, 1 / curve, 1e-5, 'angle ' .. angle .. ': distance')
    expect.near(x, (angle + half) / (2 * half) * PIXELS_WIDE, 1e-3, 'angle ' .. angle .. ': x')
    expect.near(y, PIXELS_HIGH / 2, 1e-3, 'angle ' .. angle .. ': y')
  end
  for _, angle in { half + 0.05, -half - 0.05 } do
    expect.falsy(shape.hit(panel(curve), origin, vector.pack(math.sin(angle), 0, -math.cos(angle))), 'angle ' .. angle)
  end
  local pose = lovr.math.newMat4():translate(3, 1, -1):rotate(math.pi / 2, 0, 1, 0)
  local x, _, distance = shape.hit(panel(curve, pose), vector.pack(5, 1, -1), vector.pack(-1, 0, 0))
  expect.near(x, PIXELS_WIDE / 2, 1e-3, 'the centre of the turned arc')
  expect.near(distance, 2, 1e-5, 'the radius of the turned arc')
end)

test('the outer face of a curved panel is picked only as a back face', function()
  local target = panel(0.5)
  local origin, direction = vector.pack(0, 1, -5), vector.pack(0, 0, 1)
  expect.falsy(shape.hit(target, origin, direction), 'the outer face from behind')
  target.backFace = true
  expect.near(select(3, shape.hit(target, origin, direction)), 3, 1e-5, 'the distance to the outer face')
end)

test('every vertex of the drawn arc lies on the cylinder', function()
  for _, curve in { 0.25, 2 } do
    local radius = 1 / curve
    local vertices = shape.arc(WIDTH, HEIGHT, curve, 16)
    for index, vertex in vertices do
      local x, y, z = vertex[1], vertex[2], vertex[3]
      local where = 'curve ' .. curve .. ', vertex ' .. index
      expect.near(x * x + (z - radius) ^ 2, radius * radius, 1e-6, where .. ': on the cylinder')
      expect.near(math.abs(y), HEIGHT / 2, 1e-12, where .. ': at an edge')
    end
    expect.near(vertices[1][7], 0, 1e-12, 'the arc starts at the left edge of the texture')
    expect.near(vertices[#vertices][7], 1, 1e-12, 'and ends at the right edge')
  end
end)

return test
