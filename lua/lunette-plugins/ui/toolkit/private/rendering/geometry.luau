-- Logical rectangles and route segments stay independent of the caller's world transform.
-- Bounds and routes are validated where they enter the provider; the arithmetic here trusts them.
local schema = require '@lunette-plugin/schema'
local ui = require '@lunette-contracts/ui'
local geometry = {}

export type Segment = { read from: ui.Point, read to: ui.Point }

local boundsSchema = schema.refine(schema.object {
  x = schema.number(),
  y = schema.number(),
  width = schema.number { minimum = 0 },
  height = schema.number { minimum = 0 },
})(function(bounds: ui.Bounds): ()
  assert(math.abs(bounds.x + bounds.width) < math.huge, 'right edge must be finite')
  assert(math.abs(bounds.y + bounds.height) < math.huge, 'bottom edge must be finite')
end)
local routeSchema = schema.array(schema.object { x = schema.number(), y = schema.number() })
local clipSegment: (ui.Point, ui.Point, ui.Bounds) -> Segment?

function geometry.validateBounds(bounds: ui.Bounds): ui.Bounds
  return boundsSchema.parse(bounds, 'ui bounds')
end

function geometry.validatePolyline(route: { read [number]: ui.Point }): { read [number]: ui.Point }
  return routeSchema.parse(route, 'ui route')
end

function geometry.positive(value: number, label: string): number
  assert(value > 0 and value < math.huge, 'ui geometry: ' .. label .. ' must be positive and finite')
  return value
end

function geometry.validatePose(pose: Mat4): Mat4
  local inverse = lovr.math.newMat4(pose):invert()
  for _, matrix in { pose, inverse } do
    for _, value in { matrix:unpack(true) } do
      assert(value == value and math.abs(value) < math.huge, 'ui pose: coefficients must be finite')
    end
  end
  local product = { lovr.math.newMat4(pose):mul(inverse):unpack(true) }
  for index, value in product do
    local expected = if (index - 1) % 5 == 0 then 1 else 0
    assert(math.abs(value - expected) <= 0.0001, 'ui pose: matrix must be invertible')
  end
  return pose
end

function geometry.contains(bounds: ui.Bounds, x: number?, y: number?): boolean
  return x ~= nil
    and y ~= nil
    and x >= bounds.x
    and x < bounds.x + bounds.width
    and y >= bounds.y
    and y < bounds.y + bounds.height
end

function geometry.intersect(bounds: ui.Bounds, clip: ui.Bounds): ui.Bounds?
  local x, y = math.max(bounds.x, clip.x), math.max(bounds.y, clip.y)
  local right = math.min(bounds.x + bounds.width, clip.x + clip.width)
  local bottom = math.min(bounds.y + bounds.height, clip.y + clip.height)
  if right <= x or bottom <= y then
    return nil
  end
  return table.freeze { x = x, y = y, width = right - x, height = bottom - y }
end

function geometry.sameBounds(a: ui.Bounds, b: ui.Bounds): boolean
  return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height
end

-- Return separate clipped segments; joining them would invent links between disjoint visible route parts.
function geometry.clipPolyline(route: { read [number]: ui.Point }, clip: ui.Bounds): { read [number]: Segment }
  local result: { Segment } = {}
  for index = 1, #route - 1 do
    local segment = clipSegment(route[index], route[index + 1], clip)
    if segment then
      table.insert(result, segment)
    end
  end
  return table.freeze(result)
end

clipSegment = function(from: ui.Point, to: ui.Point, clip: ui.Bounds): Segment?
  if clip.width == 0 or clip.height == 0 then
    return nil
  end
  local dx, dy = to.x - from.x, to.y - from.y
  local first, last = 0, 1
  local p = { -dx, dx, -dy, dy }
  local q = { from.x - clip.x, clip.x + clip.width - from.x, from.y - clip.y, clip.y + clip.height - from.y }
  for index = 1, 4 do
    if p[index] == 0 then
      if q[index] < 0 then
        return nil
      end
    elseif p[index] < 0 then
      first = math.max(first, q[index] / p[index])
    else
      last = math.min(last, q[index] / p[index])
    end
  end
  if last < first then
    return nil
  end
  return table.freeze {
    from = table.freeze { x = from.x + first * dx, y = from.y + first * dy },
    to = table.freeze { x = from.x + last * dx, y = from.y + last * dy },
  }
end

return geometry
