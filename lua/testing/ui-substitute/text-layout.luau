-- Independent single-line layout keeps substitute text drawing and pointer selection on the same clipped boundaries.
local lunette = require '@lunette'
local geometry = require './geometry'
local rounded = require '@lunette-plugins/theme/rounded-geometry'

local layout = {}

function layout.box(bounds, clip, style, faceClip)
  local safe = faceClip or rounded.safeClip(bounds, rounded.uniform(style.controlRadius))
  local px, py = math.min(style.padding, bounds.width / 2), math.min(style.padding, bounds.height / 2)
  return geometry.intersect(geometry.intersect(clip, safe), {
    x = bounds.x + px,
    y = bounds.y + py,
    width = bounds.width - px * 2,
    height = bounds.height - py * 2,
  })
end

function layout.field(value, caret, anchor, bounds, clip, style, font, faceClip)
  local box = layout.box(bounds, clip, style, faceClip)
  if not box then
    return nil
  end
  local height = font:getHeight()
  assert(height > 0 and height < math.huge, 'ui substitute text field: font height is finite and positive')
  local scale = math.min(style.fontSize, box.height) / height
  local boundaries = lunette.textBoundaries(value)
  local caretIndex, anchorIndex = table.find(boundaries, caret), table.find(boundaries, anchor)
  assert(caretIndex and anchorIndex, 'ui substitute text field: selection uses grapheme boundaries')
  local function advance(first, last)
    local width = font:getWidth(value:sub(first, last - 1)) * scale
    assert(width >= 0 and width < math.huge, 'ui substitute text field: font advance is finite and nonnegative')
    return width
  end
  local caretWidth = math.min(2, box.width)
  local first = caretIndex
  for index = 1, caretIndex do
    if advance(boundaries[index], caret) <= box.width - caretWidth then
      first = index
      break
    end
  end
  local start, last = boundaries[first], first
  local positions, shown = { box.x }, { boundaries[first] }
  for index = first + 1, #boundaries do
    local width = advance(start, boundaries[index])
    if width > box.width then
      break
    end
    last = index
    positions[#positions + 1] = box.x + width
    shown[#shown + 1] = boundaries[index]
  end
  assert(last >= caretIndex, 'ui substitute text field: caret remains in displayed text')
  local caretX = positions[caretIndex - first + 1]
  local selection
  if caret ~= anchor then
    local anchorX = if anchorIndex < first
      then box.x
      elseif anchorIndex > last then box.x + box.width
      else positions[anchorIndex - first + 1]
    selection = geometry.intersect({
      x = math.min(caretX, anchorX),
      y = box.y,
      width = math.abs(caretX - anchorX),
      height = height * scale,
    }, box)
  end
  return {
    text = value:sub(start, boundaries[last] - 1),
    box = box,
    scale = scale,
    boundaries = shown,
    positions = positions,
    selection = selection,
    caret = { x = caretX, y = box.y, width = caretWidth, height = height * scale },
  }
end

function layout.nearest(field, x)
  assert(geometry.finite(x), 'ui substitute text field: pointer x is finite')
  local nearest, distance = field.boundaries[1], math.huge
  for index, position in field.positions do
    local candidate = math.abs(position - x)
    if candidate < distance then
      nearest, distance = field.boundaries[index], candidate
    end
  end
  return nearest
end

return layout
