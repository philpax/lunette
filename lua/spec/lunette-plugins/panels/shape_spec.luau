-- Covers lua/lunette-plugins/panels/shape.luau.
--
-- The geometry is checked against the cylinder it describes rather than
-- against restated formulas: a ray leaving the cylinder's axis meets the arc
-- one radius away, and every vertex of the drawn arc lies on the cylinder.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local quad = require '@lunette-contracts/quad'
local shape = require '@lunette-plugins/panels/shape'

local spec = suite.new 'lunette-plugins.panels.shape'

local WIDTH, HEIGHT = 2, 1
local PIXELS_WIDE, PIXELS_HIGH = 1000, 500

local function panel(curve, pose)
  return {
    pose = pose or lovr.math.newMat4():translate(0, 1, -2),
    width = WIDTH,
    height = HEIGHT,
    pixelWidth = PIXELS_WIDE,
    pixelHeight = PIXELS_HIGH,
    curve = curve,
  }
end

spec('a panel without a curve picks as a flat quad', function()
  local random = lovr.math.newRandomGenerator(20261002)
  for case = 1, 100 do
    local target = panel(0)
    local origin = vector.pack(random:random() - 0.5, 1 + random:random() - 0.5, random:random())
    local direction = vector.pack(random:random() - 0.5, random:random() - 0.5, -1)
    local x, y, distance = shape.hit(target, origin, direction)
    local qx, qy, qd = quad.hit(target, origin, direction)
    expect.equal(x, qx, 'case ' .. case .. ': x')
    expect.equal(y, qy, 'case ' .. case .. ': y')
    expect.equal(distance, qd, 'case ' .. case .. ': distance')
  end
end)

spec('a ray leaving the axis meets the arc one radius away', function()
  -- The panel is at (0, 1, -2) facing +z, so with a radius of 2 the axis
  -- passes through the origin, and a ray from there toward any angle the arc
  -- covers meets the arc at the radius.
  local curve = 0.5
  local radius = 1 / curve
  local half = shape.halfAngle(WIDTH, curve)
  local origin = vector.pack(0, 1, 0)
  for step = -8, 8 do
    local angle = half * step / 8.5
    local x, y, distance = shape.hit(panel(curve), origin, vector.pack(math.sin(angle), 0, -math.cos(angle)))
    expect.truthy(x, 'angle ' .. angle .. ' hits')
    expect.near(distance, radius, 1e-5, 'angle ' .. angle .. ': distance')
    expect.near(x, (angle + half) / (2 * half) * PIXELS_WIDE, 1e-3, 'angle ' .. angle .. ': x')
    expect.near(y, PIXELS_HIGH / 2, 1e-3, 'angle ' .. angle .. ': y')
  end
end)

spec('a ray past either end of the arc or above it misses', function()
  local curve = 0.5
  local half = shape.halfAngle(WIDTH, curve)
  local origin = vector.pack(0, 1, 0)
  for _, angle in ipairs { half + 0.05, -half - 0.05 } do
    expect.falsy(shape.hit(panel(curve), origin, vector.pack(math.sin(angle), 0, -math.cos(angle))), 'angle ' .. angle)
  end
  expect.falsy(shape.hit(panel(curve), origin, vector.pack(0, 0.4, -1)), 'above the panel')
  expect.falsy(shape.hit(panel(curve), origin, vector.pack(0, 1, 0)), 'along the axis')
end)

spec('the outer face is picked only as a back face', function()
  local target = panel(0.5)
  local origin = vector.pack(0, 1, -5)
  local direction = vector.pack(0, 0, 1)
  expect.falsy(shape.hit(target, origin, direction), 'the outer face from behind')
  target.backFace = true
  local x, _, distance = shape.hit(target, origin, direction)
  expect.near(x, PIXELS_WIDE / 2, 1e-3, 'the centre of the outer face')
  expect.near(distance, 3, 1e-5, 'the distance to the outer face')
end)

spec('the picked arc follows the panel pose', function()
  local pose = lovr.math.newMat4():translate(3, 1, -1):rotate(math.pi / 2, 0, 1, 0)
  -- Turned a quarter turn about y, the panel faces +x, so its axis is two
  -- metres along +x from it.
  local x, _, distance = shape.hit(panel(0.5, pose), vector.pack(5, 1, -1), vector.pack(-1, 0, 0))
  expect.near(x, PIXELS_WIDE / 2, 1e-3, 'the centre of the turned arc')
  expect.near(distance, 2, 1e-5, 'the radius of the turned arc')
end)

spec('every vertex of the drawn arc lies on the cylinder', function()
  for _, curve in ipairs { 0.25, 0.5, 2, 10 } do
    local radius = 1 / curve
    local vertices, indices = shape.arc(WIDTH, HEIGHT, curve, 16)
    expect.equal(#vertices, 34, 'curve ' .. curve .. ': the vertices')
    expect.equal(#indices, 16 * 6, 'curve ' .. curve .. ': the indices')
    for index, vertex in ipairs(vertices) do
      local x, y, z, nx, _, nz, u, v = table.unpack(vertex)
      local where = 'curve ' .. curve .. ', vertex ' .. index
      expect.near(x * x + (z - radius) ^ 2, radius * radius, 1e-6, where .. ': on the cylinder')
      expect.near(math.abs(y), HEIGHT / 2, 1e-12, where .. ': at an edge')
      expect.near(nx * nx + nz * nz, 1, 1e-9, where .. ': a unit normal')
      expect.truthy(u >= 0 and u <= 1 and (v == 0 or v == 1), where .. ': the texture coordinate')
    end
    for _, vertex in ipairs(indices) do
      expect.truthy(vertex >= 1 and vertex <= #vertices, 'curve ' .. curve .. ': an index names a vertex')
    end
    expect.near(vertices[1][7], 0, 1e-12, 'the arc starts at the left edge of the texture')
    expect.near(vertices[#vertices][7], 1, 1e-12, 'and ends at the right edge')
  end
end)

spec('an arc wider than its circumference wraps no further than a turn', function()
  expect.near(shape.halfAngle(100, 1), math.pi, 1e-12, 'the half-angle')
end)

return spec
