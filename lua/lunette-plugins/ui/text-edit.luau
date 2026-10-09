-- Pure single-line edits retain one-based UTF-8 offsets at native extended grapheme boundaries.
local lunette = require '@lunette'

local edit = {}

export type State = { read value: string, read caret: number, read anchor: number }
export type Movement = 'left' | 'right' | 'home' | 'end'
export type Direction = 'backward' | 'forward'

local checkedBoundaries: (string) -> { number }
local boundaryIndex: (State, number) -> number
local replace: (State, number, number, string) -> State

function edit.new(value: string): State
  checkedBoundaries(value)
  return { value = value, caret = #value + 1, anchor = #value + 1 }
end

function edit.select(state: State, caret: number, anchor: number?): State
  local selectedAnchor = if anchor == nil then caret else anchor
  boundaryIndex(state, caret)
  boundaryIndex(state, selectedAnchor)
  return { value = state.value, caret = caret, anchor = selectedAnchor }
end

function edit.move(state: State, movement: Movement, extend: boolean): State
  local boundaries = lunette.textBoundaries(state.value)
  local position = assert(table.find(boundaries, state.caret))
  local caret = state.caret
  if movement == 'home' then
    caret = 1
  elseif movement == 'end' then
    caret = #state.value + 1
  elseif not extend and state.caret ~= state.anchor then
    caret = if movement == 'left' then math.min(state.caret, state.anchor) else math.max(state.caret, state.anchor)
  elseif movement == 'left' then
    caret = boundaries[math.max(1, position - 1)]
  else
    caret = boundaries[math.min(#boundaries, position + 1)]
  end
  return { value = state.value, caret = caret, anchor = if extend then state.anchor else caret }
end

function edit.insert(state: State, text: string): State
  checkedBoundaries(text)
  return replace(state, math.min(state.caret, state.anchor), math.max(state.caret, state.anchor), text)
end

function edit.erase(state: State, direction: Direction): State
  local first, last = math.min(state.caret, state.anchor), math.max(state.caret, state.anchor)
  if first == last then
    local boundaries = lunette.textBoundaries(state.value)
    local position = assert(table.find(boundaries, first))
    if direction == 'backward' then
      first = boundaries[math.max(1, position - 1)]
    else
      last = boundaries[math.min(#boundaries, position + 1)]
    end
  end
  return replace(state, first, last, '')
end

checkedBoundaries = function(value: string): { number }
  if utf8.len(value) == nil then
    error('text field: value must be valid UTF-8', 3)
  end
  for _, codepoint in utf8.codes(value) do
    if (codepoint >= 0xd800 and codepoint <= 0xdfff) or codepoint > 0x10ffff then
      error('text field: value must be valid Unicode UTF-8', 3)
    end
    if codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f) or codepoint == 0x2028 or codepoint == 0x2029 then
      error('text field: single-line value cannot contain control characters or line separators', 3)
    end
  end
  return lunette.textBoundaries(value)
end

boundaryIndex = function(state: State, position: number): number
  if position ~= position or position == math.huge or position == -math.huge or position % 1 ~= 0 then
    error('text field: selection must use an integer extended grapheme boundary', 3)
  end
  local index = table.find(lunette.textBoundaries(state.value), position)
  if not index then
    error('text field: selection must use an extended grapheme boundary within the value', 3)
  end
  return index
end

replace = function(state: State, first: number, last: number, text: string): State
  local value = state.value:sub(1, first - 1) .. text .. state.value:sub(last)
  local desired = first + #text
  local caret = #value + 1
  -- Combining marks, regional indicators, and ZWJ insertion can join adjacent clusters.
  for _, boundary in checkedBoundaries(value) do
    if boundary >= desired then
      caret = boundary
      break
    end
  end
  return { value = value, caret = caret, anchor = caret }
end

return edit
