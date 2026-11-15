-- Covers lua/lunette-plugins/graphics/curved-surface.luau: the cylinder maths both panel families share.

local testing = require '@testing'
local expect = testing.expect
local curved = require '../curved-surface'

local test = testing.suite()

local function surface(width: number, height: number, curve: number, axis: number): curved.Surface
  return curved.surface(width, height, curve, axis)
end

test('a flat panel maps the panel frame around its centre', function()
  local flat = surface(2, 1, 0, 0)
  local u, v, elevation = curved.toPanel(flat, 0, 0, 0.1)
  expect.near(u, 1, 1e-9, 'the horizontal centre')
  expect.near(v, 0.5, 1e-9, 'the vertical centre')
  expect.near(elevation, 0.1, 1e-9, 'the elevation')
  local hitU, hitV = curved.ray(flat, vector.pack(0.5, 0.25, 1), vector.pack(0, 0, -1), true)
  expect.near(hitU, 1.5, 1e-9, 'the hit x')
  expect.near(hitV, 0.25, 1e-9, 'the hit y')
  expect.falsy((curved.ray(flat, vector.pack(3, 0, 1), vector.pack(0, 0, -1), true)), 'a bounded miss')
  expect.truthy((curved.ray(flat, vector.pack(3, 0, 1), vector.pack(0, 0, -1), false)), 'an unbounded hit')
end)

test('a point on the cylinder maps to its arc coordinate', function()
  local curve = 1
  local cylinder = surface(2, 1, curve, 0)
  local radius = 1 / curve
  local angle = 0.4
  local u, v = curved.toPanel(cylinder, radius * math.sin(angle), 0, radius - radius * math.cos(angle))
  expect.near(u, 1 + angle / curve, 1e-9, 'the arc coordinate')
  expect.near(v, 0.5, 1e-9, 'the vertical coordinate')
end)

test('both curve signs hit the half of the cylinder that holds the panel', function()
  for _, curve in { 1, -1 } do
    local bent = surface(2, 1, curve, 0)
    local u, v, distance = curved.ray(bent, vector.pack(0, 0, 1), vector.pack(0, 0, -1), true)
    expect.near(u, 1, 1e-9, `the centre of curve {curve}`)
    expect.near(v, 0.5, 1e-9, `the mid-height of curve {curve}`)
    expect.near(distance, 1, 1e-9, `the distance of curve {curve}`)
  end
end)

test('a back-face hit reaches the far side', function()
  local bent = surface(2, 1, 1, 0)
  local front = curved.ray(bent, vector.pack(0, 0, -1), vector.pack(0, 0, 1), true)
  expect.falsy(front, 'the near side refuses a ray from behind')
  expect.truthy(curved.ray(bent, vector.pack(0, 0, -1), vector.pack(0, 0, 1), true, true), 'the back face')
end)

test('the frame follows the arc and turns about the axis', function()
  local bent = surface(2, 1, 1, 0)
  local centre = curved.frame(bent, 1, 0.5, 0)
  local x, y, z = centre:getPosition()
  expect.near(x, 0, 1e-9, 'the centre x')
  expect.near(y, 0, 1e-9, 'the centre y')
  expect.near(z, 0, 1e-9, 'the centre z')
  local angle = 0.5
  local radius = 1
  local edge = curved.frame(bent, 1 + angle, 0.5, 0)
  local ex, _, ez = edge:getPosition()
  expect.near(ex, radius * math.sin(angle), 1e-6, 'the edge x')
  expect.near(ez, radius - radius * math.cos(angle), 1e-6, 'the edge z')
end)

test('point and frame agree for flat, signed, and tilted surfaces', function()
  local points = { { 0, 0 }, { 1, 0.5 }, { 2, 1 }, { 0.25, 0.75 } }
  for _, axis in { 0, math.pi / 4, math.pi / 2 } do
    for _, curve in { 0, 1, -1 } do
      local bent = surface(2, 1, curve, axis)
      for _, at in points do
        local where = `curve {curve}, axis {axis}, point {at[1]},{at[2]}`
        local px, py, pz, nx, ny, nz = curved.point(bent, at[1], at[2])
        local frame = curved.frame(bent, at[1], at[2], 0)
        local fx, fy, fz = frame:getPosition()
        -- LÖVR matrices hold single-precision floats, so the frame agrees with the closed form to that precision.
        expect.near(fx, px, 1e-6, where .. ': x')
        expect.near(fy, py, 1e-6, where .. ': y')
        expect.near(fz, pz, 1e-6, where .. ': z')
        local dx, dy, dz = frame:mul(0, 0, 1, 0)
        expect.near(dx, nx, 1e-6, where .. ': normal x')
        expect.near(dy, ny, 1e-6, where .. ': normal y')
        expect.near(dz, nz, 1e-6, where .. ': normal z')
        expect.near(math.sqrt(nx * nx + ny * ny + nz * nz), 1, 1e-9, where .. ': unit normal')
      end
    end
  end
end)

test('a flat surface ignores its axis', function()
  for _, axis in { 0, math.pi / 4, math.pi / 2 } do
    local flat = surface(2, 1, 0, axis)
    local x, y, z, nx, ny, nz = curved.point(flat, 1.5, 0.25)
    expect.near(x, 0.5, 1e-9, 'the plane x')
    expect.near(y, 0.25, 1e-9, 'the plane y')
    expect.near(z, 0, 1e-9, 'the plane z')
    expect.equal(nx, 0, 'the normal x')
    expect.equal(ny, 0, 'the normal y')
    expect.equal(nz, 1, 'the normal z')
  end
end)

test('bend and panel coordinates round-trip', function()
  local points = { { 0, 0 }, { 1, 0.5 }, { 2, 1 }, { -0.05, 1.05 } }
  for _, axis in { 0, math.pi / 4, math.pi / 2 } do
    for _, curve in { 0, 1, -1 } do
      local bent = surface(2, 1, curve, axis)
      for _, at in points do
        local a, b = curved.bendOf(bent, at[1], at[2])
        local u, v = curved.panelOf(bent, a, b)
        expect.near(u, at[1], 1e-9, 'the panel u')
        expect.near(v, at[2], 1e-9, 'the panel v')
      end
    end
  end
end)

test('the axis normalises into the control range', function()
  expect.equal(curved.normalizeAxis(0), 0, 'zero')
  expect.near(curved.normalizeAxis(math.pi), math.pi, 1e-12, 'a half turn')
  expect.near(curved.normalizeAxis(-math.pi), math.pi, 1e-12, 'a half turn from below')
  expect.near(curved.normalizeAxis(math.pi + 0.1), -math.pi + 0.1, 1e-12, 'just past a half turn')
  expect.near(curved.normalizeAxis(-math.pi - 0.1), math.pi - 0.1, 1e-12, 'just below a half turn')
  expect.equal(curved.normalizeAxis(2 * math.pi), 0, 'a full turn')
  expect.near(curved.normalizeAxis(5), 5 - 2 * math.pi, 1e-12, 'more than a half turn')
  expect.raises(function()
    curved.normalizeAxis(0 / 0)
  end, nil, 'a NaN axis')
  expect.raises(function()
    curved.normalizeAxis(math.huge)
  end, nil, 'an infinite axis')
end)

test('the half-turn clamp is the only limit on how far a panel wraps', function()
  local width, height = 2, 4
  expect.near(curved.across(width, height, 0), 2, 1e-9, 'the width across a vertical axis')
  expect.near(curved.across(width, height, math.pi / 2), 4, 1e-9, 'the height across a horizontal axis')
  expect.near(curved.limit(2), math.pi, 1e-9, 'the curve that wraps half a turn')
  expect.equal(curved.limit(0), math.huge, 'a zero extent has no limit')
  expect.near(curved.halfAngle(2, 10), math.pi, 1e-9, 'a tight curve stops at half a turn')
  expect.near(curved.halfAngle(2, 0.5), 0.5, 1e-9, 'a gentle curve')
  expect.near(curved.curvature(2, 4, 10, 0), math.pi, 1e-9, 'a vertical bend clamps to its width')
  expect.near(curved.curvature(2, 4, 10, math.pi / 2), math.pi / 2, 1e-9, 'a horizontal bend clamps to its height')
  expect.near((curved.curvature(2, 4, -10, 0)), -math.pi, 1e-9, 'the sign survives the clamp')
end)

test('a zero-size panel has no bend', function()
  expect.equal(curved.curvature(0, 0, 1, 0), 1, 'the curve is not clamped')
  expect.equal(curved.halfAngle(0, 1), 0, 'no arc')
  local u = curved.toPanel(surface(0, 0, 1, 0), 0, 0, 0)
  expect.near(u, 0, 1e-9, 'the corner')
  expect.falsy((curved.ray(surface(0, 0, 1, 0), vector.pack(0, 0, 1), vector.pack(0, 0, -1), true)), 'no hit')
end)

return test
