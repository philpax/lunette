-- Rounded silhouettes, rectangular clipping, and outline rings use the same emitted perimeter.

local geometry = {}

export type Bounds = { read x: number, read y: number, read width: number, read height: number }
export type Point = { read x: number, read y: number }
export type Corner = { read x: number, read y: number }
export type Profile = {
  read topLeft: Corner,
  read topRight: Corner,
  read bottomRight: Corner,
  read bottomLeft: Corner,
}
export type Polygon = { read [number]: Point }

local SEGMENTS = 8
local appendTriangles: ({ { number } }, { number }, Polygon) -> ()
local corner: (number, number) -> Corner
local strip: (Polygon, Polygon, Bounds?) -> ({ { number } }, { number })
local clipped: (Polygon, (Point) -> number) -> { Point }

function geometry.uniform(radiusX: number, radiusY: number?): Profile
  local value = corner(radiusX, radiusY or radiusX)
  return table.freeze { topLeft = value, topRight = value, bottomRight = value, bottomLeft = value }
end

function geometry.profile(bounds: Bounds, given: Profile): Profile
  local function clamp(value: Corner): Corner
    return corner(math.min(value.x, bounds.width / 2), math.min(value.y, bounds.height / 2))
  end
  return table.freeze {
    topLeft = clamp(given.topLeft),
    topRight = clamp(given.topRight),
    bottomRight = clamp(given.bottomRight),
    bottomLeft = clamp(given.bottomLeft),
  }
end

function geometry.perimeter(bounds: Bounds, given: Profile): { Point }
  local profile = geometry.profile(bounds, given)
  local result: { Point } = {}
  local right, bottom = bounds.x + bounds.width, bounds.y + bounds.height
  local function arc(value: Corner, x: number, y: number, start: number): ()
    for index = 0, SEGMENTS do
      local angle = start + index / SEGMENTS * math.pi / 2
      result[#result + 1] = { x = x + value.x * math.cos(angle), y = y + value.y * math.sin(angle) }
    end
  end
  arc(profile.topLeft, bounds.x + profile.topLeft.x, bounds.y + profile.topLeft.y, math.pi)
  arc(profile.topRight, right - profile.topRight.x, bounds.y + profile.topRight.y, math.pi * 1.5)
  arc(profile.bottomRight, right - profile.bottomRight.x, bottom - profile.bottomRight.y, 0)
  arc(profile.bottomLeft, bounds.x + profile.bottomLeft.x, bottom - profile.bottomLeft.y, math.pi / 2)
  return result
end

function geometry.contains(polygon: Polygon, x: number, y: number): boolean
  if #polygon < 3 then
    return false
  end
  local area = 0
  for index, a in polygon do
    local b = polygon[index % #polygon + 1]
    local dx, dy = b.x - a.x, b.y - a.y
    local cross = dx * (y - a.y) - dy * (x - a.x)
    local tolerance = 1e-12 * (math.abs(dx) + math.abs(dy))
    if cross < -tolerance then
      return false
    end
    area += a.x * b.y - b.x * a.y
  end
  return area > 0
end

function geometry.clip(polygon: Polygon, bounds: Bounds): { Point }
  if bounds.width == 0 or bounds.height == 0 then
    return {}
  end
  local result = clipped(polygon, function(point: Point): number
    return point.x - bounds.x
  end)
  result = clipped(result, function(point: Point): number
    return bounds.x + bounds.width - point.x
  end)
  result = clipped(result, function(point: Point): number
    return point.y - bounds.y
  end)
  return clipped(result, function(point: Point): number
    return bounds.y + bounds.height - point.y
  end)
end

function geometry.safeClip(bounds: Bounds, given: Profile): Bounds
  local profile = geometry.profile(bounds, given)
  -- The 45-degree vertices belong to the emitted arcs, so this rectangle lies inside their chords.
  local factor = 1 - math.sqrt(0.5)
  local left = math.max(profile.topLeft.x, profile.bottomLeft.x) * factor
  local right = math.max(profile.topRight.x, profile.bottomRight.x) * factor
  local top = math.max(profile.topLeft.y, profile.topRight.y) * factor
  local bottom = math.max(profile.bottomLeft.y, profile.bottomRight.y) * factor
  return table.freeze {
    x = bounds.x + left,
    y = bounds.y + top,
    width = math.max(0, bounds.width - left - right),
    height = math.max(0, bounds.height - top - bottom),
  }
end

function geometry.triangles(polygon: Polygon): ({ { number } }, { number })
  local vertices: { { number } } = {}
  local indices: { number } = {}
  appendTriangles(vertices, indices, polygon)
  return vertices, indices
end

function geometry.ring(bounds: Bounds, given: Profile, thickness: number, clip: Bounds?): ({ { number } }, { number })
  local profile = geometry.profile(bounds, given)
  if thickness == 0 then
    return {}, {}
  end
  local function expand(value: Corner): Corner
    return corner(if value.x > 0 then value.x + thickness else 0, if value.y > 0 then value.y + thickness else 0)
  end
  local outerBounds = {
    x = bounds.x - thickness,
    y = bounds.y - thickness,
    width = bounds.width + thickness * 2,
    height = bounds.height + thickness * 2,
  }
  local outer = geometry.perimeter(outerBounds, {
    topLeft = expand(profile.topLeft),
    topRight = expand(profile.topRight),
    bottomRight = expand(profile.bottomRight),
    bottomLeft = expand(profile.bottomLeft),
  })
  return strip(outer, geometry.perimeter(bounds, profile), clip)
end

function geometry.insideRing(
  bounds: Bounds,
  given: Profile,
  thickness: number,
  clip: Bounds?
): ({ { number } }, { number })
  local profile = geometry.profile(bounds, given)
  thickness = math.min(thickness, bounds.width / 2, bounds.height / 2)
  if thickness == 0 then
    return {}, {}
  end
  local outer = geometry.perimeter(bounds, profile)
  local innerBounds = {
    x = bounds.x + thickness,
    y = bounds.y + thickness,
    width = bounds.width - thickness * 2,
    height = bounds.height - thickness * 2,
  }
  if innerBounds.width == 0 or innerBounds.height == 0 then
    return geometry.triangles(if clip then geometry.clip(outer, clip) else outer)
  end
  local function inset(value: Corner): Corner
    return corner(math.max(0, value.x - thickness), math.max(0, value.y - thickness))
  end
  local inner = geometry.perimeter(innerBounds, {
    topLeft = inset(profile.topLeft),
    topRight = inset(profile.topRight),
    bottomRight = inset(profile.bottomRight),
    bottomLeft = inset(profile.bottomLeft),
  })
  return strip(outer, inner, clip)
end

-- Packed doubles keep the key exact, including the sign of zero, without formatting numbers or allocating the clamped profile on
-- every draw.
local KEY = '<' .. string.rep('d', 13)
local CLIPPED_KEY = '<' .. string.rep('d', 17)

function geometry.key(bounds: Bounds, given: Profile, clip: Bounds?, thickness: number?): string
  local halfWidth, halfHeight = bounds.width / 2, bounds.height / 2
  local topLeft, topRight, bottomRight, bottomLeft = given.topLeft, given.topRight, given.bottomRight, given.bottomLeft
  local x, y, width, height = bounds.x, bounds.y, bounds.width, bounds.height
  local topLeftX, topLeftY = math.min(topLeft.x, halfWidth), math.min(topLeft.y, halfHeight)
  local topRightX, topRightY = math.min(topRight.x, halfWidth), math.min(topRight.y, halfHeight)
  local bottomRightX, bottomRightY = math.min(bottomRight.x, halfWidth), math.min(bottomRight.y, halfHeight)
  local bottomLeftX, bottomLeftY = math.min(bottomLeft.x, halfWidth), math.min(bottomLeft.y, halfHeight)
  if clip then
    return string.pack(
      CLIPPED_KEY,
      x,
      y,
      width,
      height,
      topLeftX,
      topLeftY,
      topRightX,
      topRightY,
      bottomRightX,
      bottomRightY,
      bottomLeftX,
      bottomLeftY,
      thickness or 0,
      clip.x,
      clip.y,
      clip.width,
      clip.height
    )
  end
  return string.pack(
    KEY,
    x,
    y,
    width,
    height,
    topLeftX,
    topLeftY,
    topRightX,
    topRightY,
    bottomRightX,
    bottomRightY,
    bottomLeftX,
    bottomLeftY,
    thickness or 0
  )
end

corner = function(x: number, y: number): Corner
  return table.freeze { x = x, y = y }
end

-- Both perimeters emit the same number of points, so matching indices bound one quad of the ring.
strip = function(outer: Polygon, inner: Polygon, clip: Bounds?): ({ { number } }, { number })
  local vertices: { { number } } = {}
  local indices: { number } = {}
  for index, a in outer do
    local nextIndex = index % #outer + 1
    local quad = { a, outer[nextIndex], inner[nextIndex], inner[index] }
    appendTriangles(vertices, indices, if clip then geometry.clip(quad, clip) else quad)
  end
  return vertices, indices
end

clipped = function(polygon: Polygon, distance: (Point) -> number): { Point }
  local result: { Point } = {}
  if #polygon == 0 then
    return result
  end
  local previous = polygon[#polygon]
  local before = distance(previous)
  for _, current in polygon do
    local after = distance(current)
    if (before >= 0) ~= (after >= 0) then
      local amount = before / (before - after)
      result[#result + 1] = {
        x = previous.x + (current.x - previous.x) * amount,
        y = previous.y + (current.y - previous.y) * amount,
      }
    end
    if after >= 0 then
      result[#result + 1] = current
    end
    previous, before = current, after
  end
  return result
end

appendTriangles = function(vertices: { { number } }, indices: { number }, polygon: Polygon): ()
  if #polygon < 3 then
    return
  end
  local start = #vertices
  for _, point in polygon do
    vertices[#vertices + 1] = { point.x, point.y, 0, 0, 0, 1, 0, 0 }
  end
  for index = 2, #polygon - 1 do
    indices[#indices + 1] = start + 1
    indices[#indices + 1] = start + index
    indices[#indices + 1] = start + index + 1
  end
end

return geometry
