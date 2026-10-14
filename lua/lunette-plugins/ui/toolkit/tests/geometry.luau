local testing = require '@testing'
local geometry = require '../private/rendering/geometry'
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

return test
