-- Where the keys of a keyboard are, how large the board is, and what is drawn
-- on each key.
--
-- The module is pure, and separate for the reason `mullion.panel.raycast` is:
-- this is arithmetic over rows and a lookup against a seat's keymap. The
-- other half is a live object with a pose, a target, and modifier state.
-- The module keeps no module state and installs no teardown hook.
--
-- `mullion.keyboard` re-exports the types, so a caller naming a `RenderedKey`
-- has one name for it.

local lunette = require '@lunette'

local keycodes = require '@mullion/keycodes'

local layout = {}

-- A key in a row. It matches `mullion.keycodes`'s `Key`.
export type Key = {
  code: number,
  label: string?,
  width: number?,
}
-- A row of keys.
export type KeyRow = { Key }
-- A key with its legend and calculated position.
export type RenderedKey = {
  code: number,
  modifier: string?,
  legend: string,
  x: number,
  y: number,
  width: number,
  height: number,
}

-- The measurements the layout reads. `mullion.keyboard`'s own `Style` carries
-- the colours as well and is a superset of this type.
export type Measurements = {
  read keyUnit: number,
  read gap: number,
  read margin: number,
}

-- Every key of `rows`, with its legend and its place on the board.
--
-- The origin is the board's top-left with y downwards. A raycast against the
-- keyboard returns coordinates in the same frame.
--
-- `legendFor` is called per key because a legend depends on the modifiers
-- held, and those change under the user's hands. A cached set would show the
-- unshifted legends with shift latched.
function layout.keysOf(rows: { KeyRow }, measurements: Measurements, legendFor: (Key) -> string): { RenderedKey }
  local unit = measurements.keyUnit

  local keys: { RenderedKey } = {}
  local y = 0
  for _, row in ipairs(rows) do
    local x = 0
    for _, entry: Key in ipairs(row) do
      local width = (entry.width or 1) * unit
      keys[#keys + 1] = {
        code = entry.code,
        modifier = keycodes.MODIFIERS[entry.code],
        legend = legendFor(entry),
        x = x,
        y = y,
        width = width,
        height = unit,
      }
      x = x + width
    end
    y = y + unit
  end
  return keys
end

-- How large a set of rows is, in metres: as wide as the widest row and as tall
-- as the rows are deep.
function layout.extentOf(rows: { KeyRow }, measurements: Measurements): (number, number)
  local widest = 0
  for _, row in ipairs(rows) do
    local width = 0
    for _, entry: Key in ipairs(row) do
      width = width + (entry.width or 1)
    end
    if width > widest then
      widest = width
    end
  end
  return widest * measurements.keyUnit, #rows * measurements.keyUnit
end

-- The key of `keys` that `x` and `y` fall inside, or nothing.
--
-- The coordinates run from the board's top-left with y downwards. A raycast
-- against the keyboard returns coordinates in the same frame.
function layout.keyAt(keys: { RenderedKey }, x: number, y: number): RenderedKey?
  for _, entry in ipairs(keys) do
    if x >= entry.x and x < entry.x + entry.width and y >= entry.y and y < entry.y + entry.height then
      return entry
    end
  end
  return nil
end

-- What is drawn on a key.
--
-- The label takes precedence, because a key that types a control character
-- has nothing to show. With no label, the legend comes from the seat's own
-- keymap under the modifiers held. A keysym with no text falls back to its
-- number: a key with nothing on it looks broken, and the number identifies
-- the key.
function layout.legendFor(entry: Key, seat: lunette.Seat?, modifiers: { string }): string
  if entry.label then
    return entry.label
  end
  if not seat then
    return ''
  end

  local text = seat:characterFor(entry.code, modifiers)
  if text and text ~= '' then
    return text
  end

  local symbol = seat:symbolFor(entry.code, modifiers)
  if symbol then
    return string.format('0x%x', symbol)
  end
  return ''
end

return layout
