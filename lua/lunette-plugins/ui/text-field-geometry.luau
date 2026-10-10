-- Computes the visible single-line text and measured byte-boundary positions for drawing and pointer input.
local lunette = require '@lunette'
local ui = require '@lunette-contracts/ui'
local geometry = require './geometry'
local measurement = require './measurement-cache'
local textFit = require './text-fit'
local rounded = require '@lunette-plugins/theme/rounded-geometry'
local textFieldGeometry = {}

export type Layout = {
  read text: string,
  read start: number,
  read finish: number,
  read scale: number,
  read visible: ui.Bounds,
  read origin: ui.Point,
  read boundaries: { read [number]: number },
  read positions: { read [number]: number },
  read caretBounds: ui.Bounds,
  read selectionBounds: ui.Bounds?,
  read overflow: boolean,
}

local advance: (Font, string, number) -> number

function textFieldGeometry.layout(
  value: string,
  caret: number,
  anchor: number,
  bounds: ui.Bounds,
  clip: ui.Bounds,
  theme: ui.Theme,
  font: Font,
  cache: measurement.Cache,
  faceClip: ui.Bounds?
): Layout?
  local height = font:getHeight()
  local textClip =
    geometry.intersect(clip, faceClip or rounded.safeClip(bounds, rounded.uniform(theme.controlRadius or 0)))
  local px, py = math.min(theme.padding, bounds.width / 2), math.min(theme.padding, bounds.height / 2)
  local visible = if textClip
    then geometry.intersect({
      x = bounds.x + px,
      y = bounds.y + py,
      width = bounds.width - 2 * px,
      height = bounds.height - 2 * py,
    }, textClip)
    else nil
  local scale = if visible then math.min(theme.fontSize, visible.height) / height else 0
  local entries = measurement.entries(cache, font)
  if visible then
    for index, raw in entries do
      local entry = raw :: { value: string, caret: number, anchor: number, layout: Layout }
      local result, previous = entry.layout, entry.layout.visible
      if
        entry.value == value
        and entry.caret == caret
        and entry.anchor == anchor
        and result.scale == scale
        and previous.x == visible.x
        and previous.y == visible.y
        and previous.width == visible.width
        and previous.height == visible.height
      then
        table.remove(entries, index)
        table.insert(entries, entry)
        return result
      end
    end
  end
  local boundaries = lunette.textBoundaries(value)
  local caretIndex, anchorIndex = table.find(boundaries, caret), table.find(boundaries, anchor)
  assert(caretIndex and anchorIndex, 'ui text field: selection must use an extended grapheme boundary')
  if not visible then
    return nil
  end
  local caretWidth = math.min(2, visible.width)
  local caretRoom = visible.width - caretWidth
  local first = caretIndex
  for index = 1, caretIndex do
    local width = advance(font, value:sub(boundaries[index], caret - 1), scale)
    if width <= caretRoom then
      first = index
      break
    end
  end
  local start = boundaries[first]
  local last = first
  local positions: { number } = { visible.x }
  local shownBoundaries: { number } = { start }
  for index = first + 1, #boundaries do
    local width = advance(font, value:sub(start, boundaries[index] - 1), scale)
    if width > visible.width then
      break
    end
    last = index
    table.insert(shownBoundaries, boundaries[index])
    table.insert(positions, visible.x + width)
  end
  assert(last >= caretIndex, 'ui text field: font advances must keep the caret within the displayed text')
  local caretX = positions[caretIndex - first + 1]
  local selectionBounds: ui.Bounds? = nil
  if caret ~= anchor then
    local anchorX = if anchorIndex < first
      then visible.x
      elseif anchorIndex > last then visible.x + visible.width
      else positions[anchorIndex - first + 1]
    selectionBounds = geometry.intersect({
      x = math.min(caretX, anchorX),
      y = visible.y,
      width = math.abs(caretX - anchorX),
      height = height * scale,
    }, visible)
  end
  local finish = boundaries[last]
  local result: Layout = table.freeze {
    text = textFit.singleLine(value:sub(start, finish - 1)),
    start = start,
    finish = finish,
    scale = scale,
    visible = visible,
    origin = table.freeze { x = visible.x, y = visible.y },
    boundaries = table.freeze(shownBoundaries),
    positions = table.freeze(positions),
    caretBounds = table.freeze {
      x = caretX,
      y = visible.y,
      width = caretWidth,
      height = height * scale,
    },
    selectionBounds = selectionBounds,
    overflow = first > 1 or last < #boundaries,
  }
  measurement.store(entries, { value = value, caret = caret, anchor = anchor, layout = result })
  return result
end

-- Captured pointer positions outside the field select the nearest displayed endpoint.
function textFieldGeometry.nearest(layout: Layout, x: number): number
  local nearest, distance = layout.start, math.huge
  for index, position in layout.positions do
    local candidate = math.abs(position - x)
    if candidate < distance then
      nearest, distance = layout.boundaries[index], candidate
    end
  end
  return nearest
end

advance = function(font: Font, value: string, scale: number): number
  return font:getWidth(textFit.singleLine(value)) * scale
end

return textFieldGeometry
