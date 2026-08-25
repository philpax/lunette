-- The floating error panel.
--
-- `docs/lua-api.md#errors` asks for three things at the callback boundary: a
-- log line, `lunette.onError`, and a panel. The first two are `mullion.error`'s.
-- This is the third, and it is separate for two reasons. Drawing needs a `Pass`,
-- and `mullion.error` is loaded by sessions that have no graphics module at all;
-- and a configuration that wants its own error surface should be able to leave
-- this one out rather than having to displace it.
--
-- It is a drawn quad and not a `mullion.panel`: a `mullion.panel` binds a pixel
-- source — a window or a monitor — to a pose, and an error report is neither.
--
-- What it shows is the most recent report and how many reports there have been.
-- Not a scrollback: a user reading an error in a headset wants the one that is
-- happening, and the log is where the history is. `mullion.error` has already
-- rate-limited by the time a report reaches here, so a defect raised every frame
-- updates this once per window rather than once per frame.

local errors = require '@mullion/error'
local teardown = require '@mullion/teardown'

local panel = {}

-- Declared here and defined below the public API.
local wrap

-- Where the panel sits, in metres. In front of the user at eye height and
-- nearer than a working panel usually is, because an error is what the session
-- most wants read.
panel.X, panel.Y, panel.Z = 0, 1.4, -1.1

-- How wide the panel is in metres, how tall a line of text is, and how many
-- characters a line holds before it wraps.
panel.WIDTH = 1.1
panel.TEXT_HEIGHT = 0.045
panel.COLUMNS = 64

-- How many lines of the report are shown.
--
-- A traceback is long and a headset is not a terminal. The message is what
-- names the defect; the log has the rest.
panel.LINES = 6

-- The panel's fill, as `{ r, g, b, a }`. Dark and mostly opaque, so text over it
-- is legible against whatever the session is composited over.
panel.BACKGROUND = { 0.15, 0.03, 0.03, 0.85 } :: { number }

-- The most recent report, the count since the panel was last cleared, and what
-- `errors.report` was before `install` wrapped it.
local latest: string? = nil
local count = 0
local previousReport: (string) -> () = function() end
local installed = false

-- Starts showing reports.
--
-- Wraps `errors.report`, which is the documented seam for where a report goes
-- and is called only for an occurrence that got past the rate limiter. The
-- previous sink still runs, so the log keeps everything the panel summarises.
--
-- Returns whether it installed, so that installing twice is not an error.
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

-- Puts `errors.report` back and forgets what was being shown.
--
-- Registered as this module's teardown hook. A soft reload discards the state
-- the wrapper closed over, and a configuration that does not reinstall should be
-- left with the sink it had rather than with a closure over a state that has
-- gone.
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

-- Shows `message`, replacing whatever was showing.
--
-- Public because a configuration may want to put something of its own on the
-- panel — a failed spawn, a save that did not write — without routing it through
-- the error handler.
function panel.show(message)
  latest = tostring(message)
  count = count + 1
end

-- Stops showing anything, and resets the count.
function panel.clear()
  latest, count = nil, 0
end

-- The report being shown, or nothing.
function panel.current()
  return latest
end

-- How many reports have been shown since the last `clear`.
function panel.count()
  return count
end

-- The lines the panel draws, which is the heading and the wrapped report.
--
-- Pure, and separate from `draw` because what a panel decides to say is worth
-- asserting without a `Pass` in the way.
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
-- Called from the configuration's `lovr.draw`. It does not take the whole frame:
-- a session whose error panel drew instead of its windows would be a session
-- that could not be used to fix the error.
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
      -- Just in front of the fill, so the text is not z-fighting the quad it is
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
-- Breaks on the report's own newlines first, because a message and its traceback
-- are already separated by one, then on width. Words longer than a line are cut
-- rather than allowed to run off the panel; a path or an identifier is the usual
-- case and reading most of one is better than reading none of it.
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

      -- The last space that fits, so a break lands between words when it can.
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
