-- Computes keyboard geometry and key legends.
local lunette = require '@lunette'
local keyboard = require '@lunette-contracts/keyboard'

local layout = {}

export type Key = keyboard.Key
export type KeyRow = keyboard.KeyRow
export type Action = keyboard.Action

-- Key coordinates use metres from the rows' top-left corner, with `y` increasing downward.
export type RenderedKey = {
  read source: Key,
  read code: number?,
  read action: Action?,
  read modifier: string?,
  read legend: string,
  read x: number,
  read y: number,
  read width: number,
  read height: number,
}

export type Placement = {
  read keyUnit: number,
  read modifierKeys: { [number]: string },
  read legendFor: (Key) -> string,
}

function layout.keysOf(rows: { KeyRow }, placement: Placement): { RenderedKey }
  local unit = placement.keyUnit
  local keys: { RenderedKey } = {}
  local y = 0
  for _, row in ipairs(rows) do
    local x = 0
    for _, entry in ipairs(row) do
      x += (entry.x or 0) * unit
      local width = (entry.width or 1) * unit
      if entry.code ~= nil or entry.action ~= nil then
        keys[#keys + 1] = {
          source = entry,
          code = entry.code,
          action = entry.action,
          modifier = if entry.code then placement.modifierKeys[entry.code] else nil,
          legend = placement.legendFor(entry),
          x = x,
          y = y,
          width = width,
          height = (entry.height or 1) * unit,
        }
      end
      x += width
    end
    y += layout.advanceOf(row) * unit
  end
  return keys
end

-- Rows advance by their shortest key height, or one unit when empty.
function layout.advanceOf(row: KeyRow): number
  local shortest: number? = nil
  for _, entry in ipairs(row) do
    local height = entry.height or 1
    if not shortest or height < shortest then
      shortest = height
    end
  end
  return shortest or 1
end

function layout.extentOf(rows: { KeyRow }): (number, number)
  local widest, lowest, y = 0, 0, 0
  for _, row in ipairs(rows) do
    local x = 0
    for _, entry in ipairs(row) do
      x += (entry.x or 0) + (entry.width or 1)
      lowest = math.max(lowest, y + (entry.height or 1))
    end
    widest = math.max(widest, x)
    y += layout.advanceOf(row)
  end
  return widest, math.max(lowest, y)
end

function layout.keyAt(keys: { RenderedKey }, x: number, y: number): RenderedKey?
  for _, entry in ipairs(keys) do
    if x >= entry.x and x < entry.x + entry.width and y >= entry.y and y < entry.y + entry.height then
      return entry
    end
  end
  return nil
end

-- Uses an explicit label first, then the seat keymap, then the action name.
function layout.legendFor(entry: Key, seat: lunette.Seat?, modifiers: { string }): string
  if entry.label then
    return entry.label
  end
  local action = entry.action
  if action then
    if action.kind == 'layer' then
      return action.layer
    elseif action.kind == 'text' then
      return action.text
    elseif action.kind == 'custom' then
      return action.name
    elseif action.kind == 'chord' then
      return layout.legendFor({ code = action.code }, seat, action.modifiers)
    end
    return action.kind
  end
  local code = entry.code
  if not seat or not code then
    return ''
  end

  local text = seat:characterFor(code, modifiers)
  if text and text ~= '' then
    return text
  end

  local symbol = seat:symbolFor(code, modifiers)
  if symbol then
    return string.format('0x%x', symbol)
  end
  return ''
end

return layout
