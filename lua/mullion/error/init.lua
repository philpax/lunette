-- The error handler.
--
-- docs/lua-api.md#errors puts this in mullion rather than in Rust, and says
-- why: `lovr.errhand` is overridable, so a handler living here can be replaced
-- wholesale by a configuration that wants a different one. The native layer
-- keeps exactly one failure path of its own, which is safe mode when `main.lua`
-- will not load at all.
--
-- Two boundaries, and they are not the same one.
--
-- A callback boundary. crates/lunette/src/events.rs calls each `lun*` handler
-- through a protected call and hands what comes back to
-- crates/lunette/src/callback_error.rs, which finds this module in
-- `package.loaded` and calls `errors.handle`. That is what such a boundary
-- reports through: it rate-limits, reports once, and hands the error to the
-- configuration's `lovr.lunerror`. A session without this module loaded gets
-- the log and a direct `lovr.lunerror` instead, and no rate limiting, because
-- the limiter is here.
--
-- The panel `docs/lua-api.md#errors` describes is `mullion.error.panel`, which
-- wraps `errors.report` rather than being wired in from here: a report is a
-- string and drawing one needs a `Pass`, and a session with no graphics module
-- should not be made to load a module that wants one.
--
-- The frame loop. `lovr.errhand` is reached only by an error that escaped every
-- callback boundary, at which point `vendor/lovr/etc/boot.lua:369` has already
-- unwound the loop and wants a replacement one back. There is no frame to
-- continue, so this reports and hands the loop decision on rather than
-- pretending otherwise.
--
-- Errors are rate-limited, because an error raised inside a per-frame callback
-- is raised every frame and reporting each buries the first under thousands of
-- copies of itself. Identical errors within a window are counted instead, and
-- the count is reported with the next one that gets through. The limiter is a
-- state machine over a key and a time, told the time rather than reading a
-- clock, so the specs drive it without waiting for one.

local teardown = require '@mullion/teardown'

local errors = {}

-- Declared here and defined below the public API, so the file reads
-- surface-first. The metatable is a table rather than a forward-declared local
-- because `newLimiter` runs before the methods below are filled in.
local limiterMethods = {}
local limiterMetatable = { __index = limiterMethods }
-- A representative limiter, so that the metatable and the fields line up with
-- what `newLimiter` builds.
local limiterPrototype = setmetatable({
  window = 0,
  maxKeys = 0,
  entries = {},
  order = {},
}, limiterMetatable)
type Limiter = typeof(limiterPrototype)
local touch, defaultClock

-- How long identical errors are counted for before one is let through again, in
-- seconds.
errors.WINDOW = 5

-- How many distinct errors the limiter tracks at once.
--
-- A bound is needed rather than merely tidy: an error whose message carries a
-- frame number or a pose is a distinct key every frame, and an unbounded table
-- of them is a leak that shows up only in the session that has been running
-- longest. The least recently recorded key is evicted, which at worst lets an
-- old error through again.
errors.MAX_KEYS = 64

-- Where a report goes.
--
-- Replaceable, both so that a configuration can route errors into a panel it
-- draws and so that a spec can capture them. The default logs the message,
-- which the host routes to its own diagnostics.
function errors.report(message)
  lovr.log(message, 'error', 'mullion.error')
end

-- A fresh rate limiter over its own state.
--
-- `window` is how long identical occurrences are counted for and `maxKeys` how
-- many distinct ones are tracked; both default to the constants above.
function errors.newLimiter(window: number?, maxKeys: number?): Limiter
  return setmetatable({
    window = window or errors.WINDOW,
    maxKeys = maxKeys or errors.MAX_KEYS,
    entries = {},
    -- The keys in least-recently-recorded order, so eviction has something to
    -- choose by.
    order = {},
  }, limiterMetatable)
end

-- Records an occurrence of `key` at `now`, and says what to do with it.
--
-- Returns whether this occurrence should be reported, and how many occurrences
-- were counted and not reported since the last one that was. The first sighting
-- of a key is always reported, with a suppressed count of zero.
function limiterMethods:record(key: string, now: number)
  if type(key) ~= 'string' then
    error('mullion.error: a rate-limit key is a string, not a ' .. type(key), 2)
  end
  if type(now) ~= 'number' then
    error('mullion.error: a rate limiter is told the time, and ' .. type(now) .. ' is not one', 2)
  end

  local entry = self.entries[key]
  if not entry then
    self.entries[key] = { suppressed = 0, reportedAt = now }
    self.order[#self.order + 1] = key
    self:evict()
    return true, 0
  end

  touch(self.order, key)

  if now - entry.reportedAt < self.window then
    entry.suppressed = entry.suppressed + 1
    return false, 0
  end

  local suppressed = entry.suppressed
  entry.suppressed = 0
  entry.reportedAt = now
  return true, suppressed
end

-- How many occurrences of `key` have been counted and not yet reported.
--
-- For the specs, and for a configuration drawing a panel that wants to say an
-- error is still recurring rather than only that it happened once.
function limiterMethods:suppressedCount(key)
  local entry = self.entries[key]
  return entry and entry.suppressed or 0
end

-- The limiter `errors.handle` rate-limits against, replaced on `uninstall` so
-- that a reload does not inherit the old state's suppression counts.
local limiter: Limiter = errors.newLimiter()

-- Whether `install` has run and `uninstall` has not, and what `lovr.errhand`
-- held before it did.
local installed = false
local previousHandler: ((string) -> ())? = nil

-- The key an error is rate-limited under.
--
-- The traceback is part of it because the same message raised from two places
-- is two defects, and conflating them would hide the second behind the first.
function errors.keyFor(message, traceback)
  return tostring(message) .. '\n' .. tostring(traceback or '')
end

-- Reports one error, subject to the rate limit, and hands it to the
-- configuration's `lovr.lunerror` if it defined one.
--
-- `now` is the time the error arrived at, so the caller owns the clock; it
-- defaults to the session's own. Returns whether the error was reported, which
-- is what a caller deciding whether to also draw it wants and what the specs
-- assert on.
function errors.handle(message, traceback, now)
  message = tostring(message)
  traceback = traceback and tostring(traceback) or debug.traceback('', 2)

  local report, suppressed = limiter:record(errors.keyFor(message, traceback), now or defaultClock())
  if not report then
    return false
  end

  local text = message .. '\n' .. traceback
  if suppressed > 0 then
    text = text
      .. '\n('
      .. suppressed
      .. ' identical error'
      .. (suppressed == 1 and ' was' or 's were')
      .. ' suppressed since the last report)'
  end
  errors.report(text)

  -- The configuration's own handler, per docs/lua-api.md#events. It runs under
  -- `pcall`, and only for an occurrence that got past the limiter: a handler
  -- that raises would otherwise be handled by this function, which is how one
  -- defect becomes an unbounded recursion.
  if type(lovr) == 'table' and type(lovr.lunerror) == 'function' then
    pcall(lovr.lunerror, { message = message, traceback = traceback })
  end

  return true
end

-- Installs this as `lovr.errhand`, keeping whatever was there.
--
-- LÖVR calls `lovr.errhand(message)` with no traceback and uses what it returns
-- as the replacement main loop, so this computes a traceback, reports through
-- `handle`, and hands the loop decision to the previous handler. With no
-- previous handler it returns nothing, which `boot.lua:363` turns into a loop
-- that quits: an error that escaped every callback boundary has already taken
-- the frame loop with it, and a session spinning on an empty loop would be
-- worse than one that stopped and said why.
--
-- `clock` is the time source, for a caller that wants one of its own. Returns
-- whether it installed, so that installing twice is not an error.
function errors.install(clock)
  if installed then
    return false
  end

  installed = true
  previousHandler = lovr and lovr.errhand
  -- Captured rather than read through module state, which `uninstall` clears,
  -- so the handler below has a non-nil source to call.
  local source: () -> number = clock or defaultClock

  lovr.errhand = function(message, ...)
    errors.handle(message, debug.traceback('', 2), source())
    if previousHandler then
      return previousHandler(message, ...)
    end
    return nil
  end

  teardown.register('mullion.error', errors.uninstall)
  return true
end

-- Puts back whatever `lovr.errhand` was, and forgets what has been rate-limited.
--
-- Registered as this module's teardown hook: a soft reload discards the state
-- the installed closure came from, and a configuration that does not reinstall
-- should be left with LÖVR's own handling rather than with a closure over a
-- state that has gone.
function errors.uninstall()
  if not installed then
    return false
  end

  installed = false
  if lovr then
    lovr.errhand = previousHandler
  end
  previousHandler = nil
  errors.forget()
  return true
end

-- Discards what has been rate-limited, so that the next occurrence of any error
-- is reported rather than counted.
--
-- `uninstall` calls it, which is what stops a reload inheriting the old state's
-- suppression counts and silently swallowing the new state's first error. A
-- configuration that has just fixed something and wants to see whether it is
-- fixed calls it too.
function errors.forget()
  limiter = errors.newLimiter()
end

-- Whether `install` has run and `uninstall` has not.
function errors.isInstalled()
  return installed
end

-- The limiter `handle` uses, for a spec that wants to drive it directly.
function errors.limiter()
  return limiter
end

-- Discards the least recently recorded keys until the limiter is within its
-- bound.
function limiterMethods:evict()
  while #self.order > self.maxKeys do
    local oldest = table.remove(self.order, 1)
    self.entries[oldest] = nil
  end
end

-- Moves `key` to the end of the least-recently-recorded order.
function touch(order, key)
  for index = 1, #order do
    if order[index] == key then
      table.remove(order, index)
      break
    end
  end
  order[#order + 1] = key
end

-- The time source `install` defaults to. `lovr.timer` is the session's own
-- clock and is what a limit against wall time should follow; `os.clock` is the
-- fallback for a session that switched the timer module off, which is what the
-- headless spec run does.
function defaultClock()
  if lovr and lovr.timer and lovr.timer.getTime then
    return lovr.timer.getTime()
  end
  return os.clock()
end

return errors
