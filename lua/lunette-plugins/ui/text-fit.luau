-- Single-line text fitting truncates at native extended grapheme boundaries.
local lunette = require '@lunette'

local textFit = {}

function textFit.singleLine(value: string): string
  return (value:gsub('[\r\n]', ' '))
end

-- Returns the shown text, or nil when not even the ellipsis fits, and whether the text overflowed.
function textFit.ellipsize(font: Font, value: string, scale: number, width: number): (string?, boolean)
  local line = textFit.singleLine(value)
  if line == value and font:getWidth(line) * scale <= width then
    return line, false
  end
  local suffix = '…'
  if font:getWidth(suffix) * scale > width then
    return nil, true
  end
  local boundaries = lunette.textBoundaries(line)
  local prefix = ''
  for index = 2, #boundaries do
    local candidate = line:sub(1, boundaries[index] - 1)
    if font:getWidth(candidate .. suffix) * scale <= width then
      prefix = candidate
    end
  end
  return prefix .. suffix, true
end

return textFit
