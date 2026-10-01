-- Pure error report formatting.
--
-- A report keeps the native event's message and traceback together. `key`
-- is what the limiter recognises a repeat by, `report` the text a presenter
-- shows, and `lines` that text wrapped and cut for a small surface such as
-- the desktop's error panel.

local format = {}

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

function format.lines(state: State, options: Options): { string }
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

-- What a report is recognised by when it repeats.
function format.key(report: { read message: string, read traceback: string? }): string
  return report.message .. '\n' .. (report.traceback or '')
end

function format.report(message: string, traceback: string, suppressed: number): string
  local text = message .. '\n' .. traceback
  if suppressed > 0 then
    text ..= '\n(' .. suppressed .. ' identical error' .. (suppressed == 1 and ' was' or 's were') .. ' suppressed since the last report)'
  end
  return text
end

return format
