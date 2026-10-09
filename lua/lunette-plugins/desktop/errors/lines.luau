-- Bounds the lines an error report displays.
local errorLines = {}

export type Options = {
  read columns: number,
  read lines: number,
}

export type State = {
  read latest: string?,
  read count: number,
}

local function wrap(text: string, columns: number): { string }
  local lines: { string } = {}
  for paragraph in (text .. '\n'):gmatch '([^\n]*)\n' do
    local remaining = paragraph
    if remaining == '' then
      lines[#lines + 1] = ''
    end
    while #remaining > 0 do
      if #remaining <= columns then
        lines[#lines + 1] = remaining
        break
      end

      local cut: number? = nil
      for index = columns + 1, 1, -1 do
        if remaining:sub(index, index) == ' ' then
          cut = index
          break
        end
      end

      lines[#lines + 1] = remaining:sub(1, (cut or columns + 1) - 1)
      remaining = remaining:sub((cut or columns) + 1)
    end
  end
  return lines
end

function errorLines.of(state: State, options: Options): { string }
  if not state.latest then
    return {}
  end

  local heading = 'lunette: an error was reported'
  if state.count > 1 then
    heading ..= ' (' .. state.count .. ' so far)'
  end

  local lines: { string } = { heading }
  for _, line in ipairs(wrap(state.latest, options.columns)) do
    if #lines >= options.lines then
      lines[#lines + 1] = '…'
      break
    end
    lines[#lines + 1] = line
  end
  return lines
end

return errorLines
