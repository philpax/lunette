local testing = require '@testing'
local geometry = require '../geometry'
local expect = testing.expect
local test = testing.suite()

test('half-open containment assigns shared edges to exactly one adjacent control', function()
  local left = { x = 0, y = 0, width = 10, height = 10 }
  local right = { x = 10, y = 0, width = 10, height = 10 }
  expect.truthy(geometry.contains(left, 0, 0))
  expect.falsy(geometry.contains(left, 10, 5))
  expect.truthy(geometry.contains(right, 10, 5))
  expect.falsy(geometry.contains(left, 5, 10))
  expect.falsy(geometry.contains({ x = 0, y = 0, width = 0, height = 10 }, 0, 5))
  expect.equal(geometry.intersect(left, right), nil)
end)

test('intersection is commutative, bounded, and idempotent over translated boxes', function()
  for x = -12, 12, 3 do
    for y = -9, 9, 3 do
      local a = { x = x, y = y, width = 12, height = 6 }
      local b = { x = -2, y = -2, width = 10, height = 8 }
      local ab, ba = geometry.intersect(a, b), geometry.intersect(b, a)
      expect.equal(ab == nil, ba == nil)
      if ab then
        for _, key in { 'x', 'y', 'width', 'height' } do
          expect.equal(ab[key], ba[key])
          expect.equal(geometry.intersect(ab, a)[key], ab[key])
          expect.equal(geometry.intersect(ab, b)[key], ab[key])
        end
      end
    end
  end
end)

test('polyline clipping preserves disjoint route segments rather than connecting crossings', function()
  local route = {
    { x = -5, y = 2 },
    { x = 15, y = 2 },
    { x = 15, y = 8 },
    { x = -5, y = 8 },
  }
  local segments = geometry.clipPolyline(route, { x = 0, y = 0, width = 10, height = 10 })
  expect.equal(#segments, 2)
  expect.equal(segments[1].from.x, 0)
  expect.equal(segments[1].to.x, 10)
  expect.equal(segments[1].to.y, 2)
  expect.equal(segments[2].from.x, 10)
  expect.equal(segments[2].to.x, 0)
  expect.equal(segments[2].to.y, 8)
  expect.equal(#geometry.clipPolyline({}, { x = 0, y = 0, width = 10, height = 10 }), 0)
  expect.equal(#geometry.clipPolyline({ { x = 2, y = 2 } }, { x = 0, y = 0, width = 10, height = 10 }), 0)
end)

test('pose validation accepts rigid transforms and rejects noninvertible matrices', function()
  geometry.validatePose(lovr.math.newMat4():translate(2, 3, -4):rotate(0.3, 0, 1, 0))
  expect.raises(function()
    geometry.validatePose(lovr.math.newMat4():scale(0, 1, 1))
  end)
  expect.raises(function()
    geometry.positive(0, 'width')
  end, 'width')
end)

return test
