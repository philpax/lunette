-- The floating error panel.
--
-- `docs/dev/lua-api.md#errors` requires three things at the callback boundary: a
-- log line, `lunette.onError`, and a panel. The first two are `mullion.error`'s.
-- This is the third, and it is separate for two reasons. Drawing requires a
-- `Pass`, and `mullion.error` is loaded by sessions that have no graphics
-- module. A configuration with its own error surface can leave this module
-- out.
--
-- The panel is a drawn quad and not a `mullion.panel`. A `mullion.panel` binds
-- a pixel source, a window or a monitor, to a pose, and an error report is
-- neither.
--
-- It shows the most recent report and the number of reports so far. It is not
-- a scrollback. A user reading an error in a headset needs the current report,
-- and the log holds the history. `mullion.error` rate-limits the reports this
-- module receives, so a defect raised every frame reaches the panel once per
-- window, not once per frame.

local errors = require '@mullion/error'
local teardown = require '@mullion/teardown'

local panel = {}

local wrap

-- The panel position, in metres: in front of the user at eye height and nearer
-- than a working panel usually is, because an error report is the surface the
-- user most needs to read.
panel.X, panel.Y, panel.Z = 0, 1.4, -1.1

-- The panel width in metres, the text line height in metres, and the line
-- length in characters at which text wraps.
panel.WIDTH = 1.1
panel.TEXT_HEIGHT = 0.045
panel.COLUMNS = 64

-- The number of report lines shown.
--
-- A traceback is long and a headset is not a terminal. The message names the
-- defect; the log has the rest.
panel.LINES = 6

-- The panel's fill, as `{ r, g, b, a }`. Dark and mostly opaque, so text over it
-- is legible against whatever the session is composited over.
panel.BACKGROUND = { 0.15, 0.03, 0.03, 0.85 } :: { number }

-- The most recent report, the count of reports shown between `clear` calls,
-- and the `errors.report` sink that `install` replaces.
local latest: string? = nil
local count = 0
local previousReport: (string) -> () = function() end
local installed = false

-- Starts showing reports.
--
-- Wraps `errors.report`, the documented seam a report passes through. The
-- wrapper receives each report after the rate limiter runs. The previous
-- sink still runs, so the log keeps everything the panel summarises.
--
-- Returns true when it installs, false when it is already installed.
function panel.install()
  if installed then
    return false
  end

  installed = true
  previousReport = errors.report
  errors.report = function(message: string)
    local previous = previousReport
    if previous then
      previous(message)
    end
    panel.show(message)
  end

  teardown.register('mullion.error.panel', function()
    panel.uninstall()
  end)
  return true
end

-- Puts `errors.report` back and clears the current report and count.
--
-- The teardown module calls it on soft reload. A soft reload discards the
-- Lua state the wrapper captured. The function restores the previous sink,
-- so after a reload the configuration that does not reinstall keeps a live
-- sink, not a closure over discarded state.
function panel.uninstall()
  if not installed then
    return false
  end

  installed = false
  if previousReport then
    errors.report = previousReport
  end
  previousReport = function() end
  panel.clear()
  return true
end

-- Whether `install` has run and `uninstall` has not.
function panel.isInstalled()
  return installed
end

-- Shows `message`, replacing the current report.
--
-- Public so a configuration can put something of its own on the panel, a
-- failed spawn or a failed save, without routing it through the error
-- handler.
function panel.show(message)
  latest = tostring(message)
  count = count + 1
end

-- Stops showing anything, and resets the count.
function panel.clear()
  latest, count = nil, 0
end

-- The current report, or nothing.
function panel.current()
  return latest
end

-- The number of reports shown between `clear` calls.
function panel.count()
  return count
end

-- The lines the panel draws: the heading and the wrapped report.
--
-- Pure, and separate from `draw` so tests can assert the content without a
-- `Pass`.
function panel.lines(): { string }
  if not latest then
    return {}
  end

  local heading = 'lunette: an error was reported'
  if count > 1 then
    heading = heading .. ' (' .. count .. ' so far)'
  end

  local lines: { string } = { heading }
  for _, line in ipairs(wrap(latest, panel.COLUMNS)) do
    if #lines >= panel.LINES then
      lines[#lines + 1] = '…'
      break
    end
    lines[#lines + 1] = line
  end
  return lines
end

-- Draws the panel onto `pass`, or nothing when there is nothing to show.
--
-- Called from the configuration's `lovr.draw`. It does not take the whole
-- frame, because the user needs to see the session to fix the error.
function panel.draw(pass: Pass): boolean
  local lines: { string } = panel.lines()
  if #lines == 0 then
    return false
  end

  local height = (#lines + 1) * panel.TEXT_HEIGHT * 1.5

  local red, green, blue, alpha = unpack(panel.BACKGROUND)
  pass:setColor(red, green, blue, alpha)
  pass:plane(panel.X, panel.Y, panel.Z, panel.WIDTH, height, 0, 0, 0, 0, 'fill', 1, 1)
  pass:setColor(1, 1, 1, 1)

  local top = panel.Y + height / 2 - panel.TEXT_HEIGHT * 1.5
  for index, line in ipairs(lines) do
    pass:text(
      line,
      panel.X - panel.WIDTH / 2 + panel.TEXT_HEIGHT,
      top - (index - 1) * panel.TEXT_HEIGHT * 1.5,
      -- In front of the fill, so the text does not z-fight the quad it is
      -- written on.
      panel.Z + 0.001,
      panel.TEXT_HEIGHT,
      0,
      0,
      1,
      0,
      0,
      'left',
      'middle'
    )
  end

  return true
end

-- `text` broken into lines of at most `columns` characters.
--
-- Breaks on the report's own newlines first: a message and its traceback are
-- already separated by one. It then breaks on width. Words longer than a line
-- are cut, because a path or identifier is the usual cause and reading part
-- of the word is better than reading none of it.
function wrap(text: string, columns: number): { string }
  local lines: { string } = {}
  for paragraph in (tostring(text) .. '\n'):gmatch '([^\n]*)\n' do
    local remaining = paragraph
    if remaining == '' then
      lines[#lines + 1] = ''
    end
    while #remaining > 0 do
      if #remaining <= columns then
        lines[#lines + 1] = remaining
        break
      end

      -- The last space that fits within the column limit, so a break lands
      -- between words when it can.
      local cut = nil
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

return panel
