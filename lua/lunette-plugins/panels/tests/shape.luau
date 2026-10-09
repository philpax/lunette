local testing = require '@testing'
local expect = testing.expect

local quad = require '@lunette-contracts/quad'
local shape = require '@lunette-plugins/panels/shape'
local geometry = require '@lunette-plugins/theme/rounded-geometry'

local test = testing.suite()

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

test('a panel without a curve picks as a flat quad', function()
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
  local rounded = panel(0)
  rounded.polygon = geometry.perimeter({ x = 0, y = 0, width = WIDTH, height = HEIGHT }, geometry.uniform(0.2))
  local angle = math.pi + math.pi / 32
  local chordRadius = 0.2 * (1 + math.cos(math.pi / 32)) / 2
  local px, py = 0.2 + chordRadius * math.cos(angle), 0.2 + chordRadius * math.sin(angle)
  local origin = vector.pack(px - WIDTH / 2, 1 + HEIGHT / 2 - py, 0)
  expect.truthy(quad.hit(rounded, origin, vector.pack(0, 0, -1)), 'the corner remains inside the source quad')
  expect.falsy(shape.hit(rounded, origin, vector.pack(0, 0, -1)), 'the point between the arc chord and circle misses')
end)

test('a ray leaving the axis meets the arc one radius away', function()
  -- The panel's axis passes through the ray origin, so every covered angle intersects at one radius.
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

test('a ray past either end of the arc or above it misses, and an arc wraps no further than a turn', function()
  local curve = 0.5
  local half = shape.halfAngle(WIDTH, curve)
  local origin = vector.pack(0, 1, 0)
  for _, angle in ipairs { half + 0.05, -half - 0.05 } do
    expect.falsy(shape.hit(panel(curve), origin, vector.pack(math.sin(angle), 0, -math.cos(angle))), 'angle ' .. angle)
  end
  expect.falsy(shape.hit(panel(curve), origin, vector.pack(0, 0.4, -1)), 'above the panel')
  expect.falsy(shape.hit(panel(curve), origin, vector.pack(0, 1, 0)), 'along the axis')
  expect.near(shape.halfAngle(100, 1), math.pi, 1e-12, 'the half-angle of an arc wider than its circumference')
end)

test('the outer face is picked only as a back face', function()
  local target = panel(0.5)
  local origin = vector.pack(0, 1, -5)
  local direction = vector.pack(0, 0, 1)
  expect.falsy(shape.hit(target, origin, direction), 'the outer face from behind')
  target.backFace = true
  local x, _, distance = shape.hit(target, origin, direction)
  expect.near(x, PIXELS_WIDE / 2, 1e-3, 'the centre of the outer face')
  expect.near(distance, 3, 1e-5, 'the distance to the outer face')
end)

test('the picked arc follows the panel pose', function()
  local pose = lovr.math.newMat4():translate(3, 1, -1):rotate(math.pi / 2, 0, 1, 0)
  -- The rotated panel faces +x, with its axis two metres from the pose.
  local x, _, distance = shape.hit(panel(0.5, pose), vector.pack(5, 1, -1), vector.pack(-1, 0, 0))
  expect.near(x, PIXELS_WIDE / 2, 1e-3, 'the centre of the turned arc')
  expect.near(distance, 2, 1e-5, 'the radius of the turned arc')
  local target = panel(0.5, pose)
  target.polygon = geometry.perimeter({ x = 0, y = 0, width = WIDTH, height = HEIGHT }, geometry.uniform(0.2))
  local function ray(px, py)
    local angle = (2 * px / WIDTH - 1) * shape.halfAngle(WIDTH, target.curve)
    local dx, dy, dz = pose:mul(math.sin(angle), 0, -math.cos(angle), 0)
    local ox, oy, oz = pose:mul(0, HEIGHT / 2 - py, 2, 1)
    return vector.pack(ox, oy, oz), vector.pack(dx, dy, dz)
  end
  local roundedX = shape.hit(target, ray(WIDTH / 2, HEIGHT / 2))
  expect.near(roundedX, PIXELS_WIDE / 2, 1e-3, 'rounding retains the posed arc centre')
  expect.falsy(shape.hit(target, ray(0.005, 0.005)), 'the posed curved cutout is not pickable')
end)

test('every vertex of the drawn arc lies on the cylinder', function()
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
    local polygon = geometry.perimeter({ x = 0, y = 0, width = WIDTH, height = HEIGHT }, geometry.uniform(0.2))
    local rounded, triangles = shape.rounded(WIDTH, HEIGHT, curve, polygon)
    for _, vertex in rounded do
      expect.near(vertex[1] ^ 2 + (vertex[3] - radius) ^ 2, radius ^ 2, 1e-6, 'rounded vertices remain on the cylinder')
      expect.truthy(
        geometry.contains(polygon, vertex[7] * WIDTH, vertex[8] * HEIGHT),
        'UVs retain their unclipped source position'
      )
      expect.near(vertex[2], HEIGHT / 2 - vertex[8] * HEIGHT, 1e-12, 'source y maps to native y-up')
    end
    for index = 1, #triangles, 3 do
      local minimum, maximum = 1, 0
      for offset = 0, 2 do
        local u = rounded[triangles[index + offset]][7]
        minimum, maximum = math.min(minimum, u), math.max(maximum, u)
      end
      expect.truthy(maximum - minimum <= 1 / shape.SEGMENTS + 1e-12, 'rounded triangles remain inside an arc strip')
    end
  end
end)

return test
