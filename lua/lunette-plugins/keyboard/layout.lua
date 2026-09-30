-- Keyboard geometry and legends.
--
-- This module is pure. It keeps no registry, installs no hooks, and only reads
-- the key rows, measurements, and seat supplied by its caller.

local lunette = require '@lunette'
local keyboard = require '@lunette-contracts/keyboard'
local keycodes = require '@mullion/keycodes'

local layout = {}

export type Measurements = {
  read keyUnit: number,
  read gap: number,
  read margin: number,
}

export type Key = keyboard.Key
export type KeyRow = keyboard.KeyRow
export type RenderedKey = keyboard.RenderedKey

function layout.keysOf(rows: { KeyRow }, measurements: Measurements, legendFor: (Key) -> string): { RenderedKey }
  local unit = measurements.keyUnit
  local keys: { RenderedKey } = {}
  local y = 0
  for _, row in ipairs(rows) do
    local x = 0
    for _, entry in ipairs(row) do
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

function layout.extentOf(rows: { KeyRow }, measurements: Measurements): (number, number)
  local widest = 0
  for _, row in ipairs(rows) do
    local width = 0
    for _, entry in ipairs(row) do
      width = width + (entry.width or 1)
    end
    if width > widest then
      widest = width
    end
  end
  return widest * measurements.keyUnit, #rows * measurements.keyUnit
end

function layout.keyAt(keys: { RenderedKey }, x: number, y: number): RenderedKey?
  for _, entry in ipairs(keys) do
    if x >= entry.x and x < entry.x + entry.width and y >= entry.y and y < entry.y + entry.height then
      return entry
    end
  end
  return nil
end

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
