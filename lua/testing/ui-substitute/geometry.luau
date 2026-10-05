-- Validates logical bounds and clips without relocating layout origins.

local geometry = {}

function geometry.finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

function geometry.bounds(value)
  assert(
    geometry.finite(value.x)
      and geometry.finite(value.y)
      and geometry.finite(value.width)
      and geometry.finite(value.height)
      and value.width > 0
      and value.height > 0,
    'ui substitute: bounds are finite and positive'
  )
  return table.freeze { x = value.x, y = value.y, width = value.width, height = value.height }
end

function geometry.intersect(a, b)
  if not a or not b then
    return nil
  end
  local x, y = math.max(a.x, b.x), math.max(a.y, b.y)
  local right, bottom = math.min(a.x + a.width, b.x + b.width), math.min(a.y + a.height, b.y + b.height)
  if right <= x or bottom <= y then
    return nil
  end
  return table.freeze { x = x, y = y, width = right - x, height = bottom - y }
end

function geometry.contains(box, x, y)
  return box and x and y and x >= box.x and y >= box.y and x < box.x + box.width and y < box.y + box.height
end

return geometry
