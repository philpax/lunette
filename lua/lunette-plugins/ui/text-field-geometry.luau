-- Computes the visible single-line text and measured byte-boundary positions for drawing and pointer input.
local lunette = require '@lunette'
local ui = require '@lunette-contracts/ui'
local geometry = require './geometry'
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

type CacheEntry = {
  read value: string,
  read caret: number,
  read anchor: number,
  read layout: Layout,
}

type FontCache = {
  read measure: unknown,
  read height: number,
  read density: number?,
  read entries: { CacheEntry },
}

local CACHE_LIMIT = 32
local cacheFor: (Font, number) -> { CacheEntry }
local advance: (Font, string, number) -> number
local singleLine: (string) -> string

function textFieldGeometry.layout(
  value: string,
  caret: number,
  anchor: number,
  bounds: ui.Bounds,
  clip: ui.Bounds,
  theme: ui.Theme,
  font: Font
): Layout?
  geometry.validateBounds(bounds)
  geometry.validateBounds(clip)
  assert(theme.padding >= 0 and theme.padding < math.huge, 'ui text field: padding must be nonnegative and finite')
  geometry.positive(theme.fontSize, 'font size')
  local height = geometry.positive(font:getHeight(), 'font height')
  local px, py = math.min(theme.padding, bounds.width / 2), math.min(theme.padding, bounds.height / 2)
  local visible = geometry.intersect({
    x = bounds.x + px,
    y = bounds.y + py,
    width = bounds.width - 2 * px,
    height = bounds.height - 2 * py,
  }, clip)
  local scale = if visible then math.min(theme.fontSize, visible.height) / height else 0
  local cached = if visible then cacheFor(font, height) else nil
  if cached and visible then
    for index, entry in cached do
      local result = entry.layout
      local previous = result.visible
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
        table.remove(cached, index)
        table.insert(cached, entry)
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
    text = singleLine(value:sub(start, finish - 1)),
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
  if cached then
    if #cached == CACHE_LIMIT then
      table.remove(cached, 1)
    end
    table.insert(cached, { value = value, caret = caret, anchor = anchor, layout = result })
  end
  return result
end

-- Captured pointer positions outside the field select the nearest displayed endpoint.
function textFieldGeometry.nearest(layout: Layout, x: number): number
  assert(x == x and math.abs(x) < math.huge, 'ui text field: pointer x must be finite')
  local nearest, distance = layout.start, math.huge
  for index, position in layout.positions do
    local candidate = math.abs(position - x)
    if candidate < distance then
      nearest, distance = layout.boundaries[index], candidate
    end
  end
  return nearest
end

local fontCaches: { [Font]: FontCache } = setmetatable({}, { __mode = 'k' })

cacheFor = function(font: Font, height: number): { CacheEntry }
  -- Single-line metrics depend on the font and its pixel density, not its atlas or line spacing.
  local density = if font.getPixelDensity then font:getPixelDensity() else nil
  local cached = fontCaches[font]
  if not cached or cached.measure ~= font.getWidth or cached.height ~= height or cached.density ~= density then
    cached = { measure = font.getWidth, height = height, density = density, entries = {} }
    fontCaches[font] = cached
  end
  return cached.entries
end

advance = function(font: Font, value: string, scale: number): number
  local width = font:getWidth(singleLine(value)) * scale
  assert(width >= 0 and width < math.huge, 'ui text field: font advance must be nonnegative and finite')
  return width
end

singleLine = function(value: string): string
  return (value:gsub('[\r\n]', ' '))
end

return textFieldGeometry
