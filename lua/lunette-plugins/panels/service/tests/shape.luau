local testing = require '@testing'
local expect = testing.expect

local quad = require '@lunette-contracts/quad'
local shape = require '../private/shape'
local geometry = require '@lunette-plugins/graphics/rounded-geometry'
local curved = require '@lunette-plugins/graphics/curved-surface'

local test = testing.suite()

type Panel = {
  pose: Mat4,
  width: number,
  height: number,
  pixelWidth: number,
  pixelHeight: number,
  curve: number,
  curveAxis: number,
  polygon: { geometry.Point }?,
  backFace: boolean?,
}

local WIDTH, HEIGHT = 2, 1
local PIXELS_WIDE, PIXELS_HIGH = 1000, 500
local AXES = { 0, math.pi / 4, math.pi / 2 }
local CURVES = { 0, 0.5, -0.5 }

local function panel(curve: number, pose: Mat4?, axis: number?): Panel
  return {
    pose = pose or lovr.math.newMat4():translate(0, 1, -2),
    width = WIDTH,
    height = HEIGHT,
    pixelWidth = PIXELS_WIDE,
    pixelHeight = PIXELS_HIGH,
    curve = curve,
    curveAxis = axis or 0,
  }
end

-- A ray that reaches the surface at a panel coordinate from a metre out along its normal.
local function aimed(surface: curved.Surface, u: number, v: number): (vector, vector)
  local x, y, z, nx, ny, nz = curved.point(surface, u, v)
  return vector.pack(x + nx, y + ny, z + nz), vector.pack(-nx, -ny, -nz)
end

local function world(pose: Mat4, direction: vector): vector
  local x, y, z = direction:unpack()
  return vector.pack(pose:mul(x, y, z, 0))
end

local function roundedPolygon(): { geometry.Point }
  return geometry.perimeter({ x = 0, y = 0, width = WIDTH, height = HEIGHT }, geometry.uniform(0.2))
end

local function outline(): ({ { number } }, { number })
  return geometry.ring({ x = 0, y = 0, width = WIDTH, height = HEIGHT }, geometry.uniform(0.2), 0.02)
end

-- Every vertex agrees with the shared surface at its texture coordinate.
local function checkVertices(
  vertices: { { number } },
  width: number,
  height: number,
  curve: number,
  axis: number,
  where: string
): ()
  local surface = curved.surface(width, height, curve, axis)
  for index, vertex in vertices do
    local u, v = vertex[7] * width, vertex[8] * height
    local x, y, z, nx, ny, nz = curved.point(surface, u, v)
    local at = where .. ', vertex ' .. index
    expect.near(vertex[1], x, 1e-6, at .. ': x')
    expect.near(vertex[2], y, 1e-6, at .. ': y')
    expect.near(vertex[3], z, 1e-6, at .. ': z')
    expect.near(vertex[4], nx, 1e-6, at .. ': normal x')
    expect.near(vertex[5], ny, 1e-6, at .. ': normal y')
    expect.near(vertex[6], nz, 1e-6, at .. ': normal z')
  end
end

-- A front face turns anticlockwise about its vertex normals.
local function checkWinding(vertices: { { number } }, indices: { number }, where: string): ()
  for index = 1, #indices, 3 do
    local a, b, c = vertices[indices[index]], vertices[indices[index + 1]], vertices[indices[index + 2]]
    local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
    local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
    local cx, cy, cz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    local length = math.sqrt(cx * cx + cy * cy + cz * cz)
    if length > 1e-9 then
      local nx, ny, nz = a[4] + b[4] + c[4], a[5] + b[5] + c[5], a[6] + b[6] + c[6]
      expect.truthy(cx * nx + cy * ny + cz * nz > 0, where .. `: triangle {index} faces out`)
    end
  end
end

local function meshArea(vertices: { { number } }, indices: { number }): number
  local area = 0
  for index = 1, #indices, 3 do
    local a, b, c = vertices[indices[index]], vertices[indices[index + 1]], vertices[indices[index + 2]]
    local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
    local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
    local cx, cy, cz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    area += math.sqrt(cx * cx + cy * cy + cz * cz) / 2
  end
  return area
end

-- The bend-frame extent of a set of points, each scaled by `stride` into panel coordinates.
local function bendExtent(
  surface: curved.Surface,
  points: { { number } },
  scaleX: number,
  scaleY: number
): (number, number, number, number)
  local minA, maxA, minB, maxB = math.huge, -math.huge, math.huge, -math.huge
  for _, point in points do
    local a, b = curved.bendOf(surface, point[1] * scaleX, point[2] * scaleY)
    minA, maxA = math.min(minA, a), math.max(maxA, a)
    minB, maxB = math.min(minB, b), math.max(maxB, b)
  end
  return minA, maxA, minB, maxB
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
  rounded.polygon = roundedPolygon()
  local corner = vector.pack(0.01 - WIDTH / 2, 1 + HEIGHT / 2 - 0.01, 0)
  expect.truthy(quad.hit(rounded, corner, vector.pack(0, 0, -1)), 'the corner lies inside the quad')
  expect.falsy(shape.hit(rounded, corner, vector.pack(0, 0, -1)), 'the corner outside the rounding misses')
end)

test('a tilted native panel maps a ray to the expected planar pixel', function()
  local pose = lovr.math.newMat4():translate(0, 1, -2)
  for _, axis in AXES do
    local target = panel(0.5, pose, axis)
    local surface = curved.surface(WIDTH, HEIGHT, 0.5, axis)
    for _, u in { 0.25, 1, 1.75 } do
      local where = `axis {axis}, u {u}`
      local origin, direction = aimed(surface, u, HEIGHT / 2)
      local pixelX, pixelY = shape.hit(target, pose:mul(origin), world(pose, direction))
      expect.truthy(pixelX, where .. ': the hit')
      expect.near(pixelX, u / WIDTH * PIXELS_WIDE, 1e-3, where .. ': the pixel across')
      expect.near(pixelY, PIXELS_HIGH / 2, 1e-3, where .. ': the pixel down')
    end
  end
end)

test('a signed native panel maps a ray through the shared surface', function()
  local pose = lovr.math.newMat4():translate(0, 1, -2)
  for _, axis in AXES do
    local target = panel(-0.5, pose, axis)
    local surface = curved.surface(WIDTH, HEIGHT, -0.5, axis)
    for _, u in { 0.25, 1, 1.75 } do
      local where = `axis {axis}, u {u}`
      local origin, direction = aimed(surface, u, HEIGHT / 2)
      local pixelX, pixelY = shape.hit(target, pose:mul(origin), world(pose, direction))
      expect.truthy(pixelX, where .. ': the hit')
      expect.near(pixelX, u / WIDTH * PIXELS_WIDE, 1e-3, where .. ': the pixel across')
      expect.near(pixelY, PIXELS_HIGH / 2, 1e-3, where .. ': the pixel down')
    end
  end
end)

test('a curved panel picks on its arc, follows its pose, and misses past either end', function()
  local curve = 0.5
  local half = curved.halfAngle(curved.across(WIDTH, HEIGHT, 0), curve)
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

test('a tilted front-face hit faces the ray', function()
  local random = lovr.math.newRandomGenerator(20261110)
  for _, axis in AXES do
    local target = panel(0.5, nil, axis)
    local surface = curved.surface(WIDTH, HEIGHT, 0.5, axis)
    for case = 1, 50 do
      local origin = vector.pack(random:random() - 0.5, 1 + random:random() - 0.5, random:random())
      local direction = vector.pack(random:random() - 0.5, random:random() - 0.5, -1)
      local x, y = shape.hit(target, origin, direction)
      if x and y then
        local u, v = x / PIXELS_WIDE * WIDTH, y / PIXELS_HIGH * HEIGHT
        local _, _, _, nx, ny, nz = curved.point(surface, u, v)
        local facing = nx * direction.x + ny * direction.y + nz * direction.z
        expect.truthy(facing < 1e-9, `axis {axis}, case {case}: the front face opposes the ray`)
      end
    end
  end
end)

test('an oblique ray at a tilted panel lands where it was aimed', function()
  local pose = lovr.math.newMat4():translate(0, 1, -2)
  for _, axis in AXES do
    for _, curve in { 0.5, -0.5 } do
      local target = panel(curve, pose, axis)
      local surface = curved.surface(WIDTH, HEIGHT, curve, axis)
      for _, u in { 0.25, 1, 1.75 } do
        for _, v in { 0.2, 0.5, 0.8 } do
          local x, y, z, nx, ny, nz = curved.point(surface, u, v)
          local a, b = curved.bendOf(surface, u, v)
          local angle = a * surface.curve
          local tx, ty, tz = math.cos(axis) * math.cos(angle), math.sin(axis) * math.cos(angle), math.sin(angle)
          -- A metre out along the normal and a metre along the surface, so the ray reaches the face obliquely.
          local origin = vector.pack(x + nx + tx, y + ny + ty, z + nz + tz)
          local direction = vector.pack(x - origin.x, y - origin.y, z - origin.z)
          local pixelX, pixelY = shape.hit(target, pose:mul(origin), world(pose, direction))
          local where = `axis {axis}, curve {curve}, u {u}, v {v}`
          expect.truthy(pixelX, where .. ': the hit')
          expect.near(pixelX, u / WIDTH * PIXELS_WIDE, 1e-2, where .. ': the pixel across')
          expect.near(pixelY, v / HEIGHT * PIXELS_HIGH, 1e-2, where .. ': the pixel down')
        end
      end
    end
  end
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
    local vertices = shape.arc(WIDTH, HEIGHT, curve, 0, 16)
    for index, vertex in vertices do
      local x, y, z = vertex[1], vertex[2], vertex[3]
      local where = 'curve ' .. curve .. ', vertex ' .. index
      expect.near(x * x + (z - radius) ^ 2, radius * radius, 1e-6, where .. ': on the cylinder')
      expect.near(math.abs(y), HEIGHT / 2, 1e-12, where .. ': at an edge')
    end
    local minU, maxU = math.huge, -math.huge
    for _, vertex in vertices do
      minU, maxU = math.min(minU, vertex[7]), math.max(maxU, vertex[7])
    end
    expect.near(minU, 0, 1e-12, 'the arc starts at the left edge of the texture')
    expect.near(maxU, 1, 1e-12, 'and ends at the right edge')
  end
end)

test('tilted and signed arc, rounded, and outline vertices lie on the shared surface', function()
  for _, axis in AXES do
    for _, curve in CURVES do
      local where = `axis {axis}, curve {curve}`
      local arcVertices, arcIndices = shape.arc(WIDTH, HEIGHT, curve, axis, 16)
      checkVertices(arcVertices, WIDTH, HEIGHT, curve, axis, where .. ': arc')
      checkWinding(arcVertices, arcIndices, where .. ': arc')

      local roundedVertices, roundedIndices = shape.rounded(WIDTH, HEIGHT, curve, axis, roundedPolygon())
      checkVertices(roundedVertices, WIDTH, HEIGHT, curve, axis, where .. ': rounded')
      checkWinding(roundedVertices, roundedIndices, where .. ': rounded')

      local points, triangles = outline()
      local outlineVertices, outlineIndices = shape.mapTriangles(WIDTH, HEIGHT, curve, axis, points, triangles)
      checkVertices(outlineVertices, WIDTH, HEIGHT, curve, axis, where .. ': outline')
      checkWinding(outlineVertices, outlineIndices, where .. ': outline')
    end
  end
end)

local function meshBendExtent(
  surface: curved.Surface,
  vertices: { { number } },
  width: number,
  height: number
): (number, number, number, number)
  local points: { { number } } = {}
  for _, vertex in vertices do
    points[#points + 1] = { vertex[7] * width, vertex[8] * height }
  end
  return bendExtent(surface, points, 1, 1)
end

test('a tilted outline keeps its outer ring', function()
  local points, triangles = outline()
  local flatVertices, flatIndices = shape.mapTriangles(WIDTH, HEIGHT, 0.5, 0, points, triangles)
  local flatArea = meshArea(flatVertices, flatIndices)
  for _, axis in { 0, math.pi / 4, math.pi / 2 } do
    local surface = curved.surface(WIDTH, HEIGHT, 0.5, axis)
    local ringMinA, ringMaxA, ringMinB, ringMaxB = bendExtent(surface, points, 1, 1)
    local vertices, indices = shape.mapTriangles(WIDTH, HEIGHT, 0.5, axis, points, triangles)
    local meshMinA, meshMaxA, meshMinB, meshMaxB = meshBendExtent(surface, vertices, WIDTH, HEIGHT)
    local where = `axis {axis}`
    expect.near(meshMinA, ringMinA, 1e-6, where .. ': the near across edge')
    expect.near(meshMaxA, ringMaxA, 1e-6, where .. ': the far across edge')
    expect.near(meshMinB, ringMinB, 1e-6, where .. ': the near along edge')
    expect.near(meshMaxB, ringMaxB, 1e-6, where .. ': the far along edge')
    -- A developable cylinder preserves the ring's area, so a clipped corner would show as missing coverage.
    expect.near(meshArea(vertices, indices), flatArea, flatArea * 0.01, where .. ': the ring area')
  end
end)

test('a tilted panel past the half-turn limit wraps once', function()
  local width, curve, axis = 4.1, 4, math.pi / 4
  local surface = curved.surface(width, 1, curve, axis)
  local vertices, indices = shape.arc(width, 1, curve, axis, 8)
  expect.truthy(#indices > 0, 'the clamped arc has triangles')
  local minA, maxA = math.huge, -math.huge
  for _, vertex in vertices do
    local a = curved.bendOf(surface, vertex[7] * width, vertex[8])
    minA, maxA = math.min(minA, a), math.max(maxA, a)
  end
  expect.near(maxA * surface.curve, math.pi, 1e-6, 'the arc reaches a half turn one way')
  expect.near(minA * surface.curve, -math.pi, 1e-6, 'and the other')
  local roundedVertices = shape.rounded(width, 1, curve, axis, {
    { x = 0, y = 0 },
    { x = width, y = 0 },
    { x = width, y = 1 },
    { x = 0, y = 1 },
  })
  expect.truthy(#roundedVertices > 0, 'the rounded mesh has vertices')
  checkVertices(roundedVertices, width, 1, curve, axis, 'the clamped rounded mesh')
end)

test('a flat mesh maps to the plane and keeps its UV endpoints', function()
  local vertices = shape.arc(WIDTH, HEIGHT, 0, 0, 8)
  for index, vertex in vertices do
    local where = 'vertex ' .. index
    expect.near(vertex[3], 0, 1e-12, where .. ': the plane z')
    expect.equal(vertex[4], 0, where .. ': the plane normal x')
    expect.equal(vertex[5], 0, where .. ': the plane normal y')
    expect.equal(vertex[6], 1, where .. ': the plane normal z')
    expect.near(vertex[1], vertex[7] * WIDTH - WIDTH / 2, 1e-9, where .. ': x from u')
    expect.near(vertex[2], HEIGHT / 2 - vertex[8] * HEIGHT, 1e-9, where .. ': y from v')
  end
  local minU, maxU = math.huge, -math.huge
  for _, vertex in vertices do
    minU, maxU = math.min(minU, vertex[7]), math.max(maxU, vertex[7])
  end
  expect.equal(minU, 0, 'the left edge of the texture')
  expect.equal(maxU, 1, 'the right edge')
end)

return test
