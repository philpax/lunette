-- Covers lua/mullion/error.lua.

local expect = require 'spec.expect'
local suite = require 'spec.suite'

local errors = require 'mullion.error'
local teardown = require 'mullion.teardown'

local spec = suite.new 'mullion.error'

-- Captures reports and starts from an uninstalled handler with an empty
-- limiter, returning the list reports land in.
local function fresh()
  errors.uninstall()
  -- Again, because `uninstall` returns early when nothing was installed and
  -- most cases here never install. Without it a case would inherit the previous
  -- case's suppression counts.
  errors.forget()

  local reports = {}
  errors.report = function(message)
    reports[#reports + 1] = message
  end
  return reports
end

-- A clock the case advances by hand. Nothing here waits for a real one:
-- CONTRIBUTING.md's rule is to wait for conditions rather than durations, and a
-- rate limiter's window is exactly the thing to inject rather than sleep
-- through.
local function clock()
  local time = { now = 0 }
  function time.advance(seconds)
    time.now = time.now + seconds
  end
  function time.read()
    return time.now
  end
  return time
end

spec('reports the first occurrence of an error', function()
  local reports = fresh()

  expect.truthy(errors.handle('it broke', 'a traceback', 0), 'handle')
  expect.equal(#reports, 1, 'report count')
  expect.truthy(reports[1]:find('it broke'), 'the message')
  expect.truthy(reports[1]:find('a traceback'), 'the traceback')
end)

spec('suppresses identical errors within the window', function()
  local reports = fresh()

  errors.handle('it broke', 'a traceback', 0)
  for _ = 1, 100 do
    expect.falsy(errors.handle('it broke', 'a traceback', 0.5), 'a suppressed occurrence')
  end

  expect.equal(#reports, 1, 'report count')
end)

spec('reports a count when the window has elapsed', function()
  local reports = fresh()

  errors.handle('it broke', 'a traceback', 0)
  errors.handle('it broke', 'a traceback', 1)
  errors.handle('it broke', 'a traceback', 2)
  expect.truthy(errors.handle('it broke', 'a traceback', errors.WINDOW), 'the occurrence after the window')

  expect.equal(#reports, 2, 'report count')
  expect.truthy(reports[2]:find('2 identical errors were suppressed'), 'the count: ' .. reports[2])
end)

spec('a single suppressed error is counted in the singular', function()
  local reports = fresh()

  errors.handle('it broke', 'a traceback', 0)
  errors.handle('it broke', 'a traceback', 1)
  errors.handle('it broke', 'a traceback', errors.WINDOW)

  expect.truthy(reports[2]:find('1 identical error was suppressed'), 'the count: ' .. reports[2])
end)

spec('a report with nothing suppressed says nothing about suppression', function()
  local reports = fresh()

  errors.handle('it broke', 'a traceback', 0)
  errors.handle('it broke', 'a traceback', errors.WINDOW)

  expect.falsy(reports[2]:find('suppressed'), 'the second report')
end)

spec('does not conflate distinct messages', function()
  local reports = fresh()

  errors.handle('the first', 'a traceback', 0)
  errors.handle('the second', 'a traceback', 0)

  expect.equal(#reports, 2, 'report count')
end)

spec('does not conflate one message raised from two places', function()
  local reports = fresh()

  errors.handle('it broke', 'the first traceback', 0)
  errors.handle('it broke', 'the second traceback', 0)

  expect.equal(#reports, 2, 'report count')
end)

spec('the limiter tracks distinct keys independently', function()
  local limiter = errors.newLimiter(5, 64)

  expect.truthy(limiter:record('a', 0), 'a at 0')
  expect.truthy(limiter:record('b', 0), 'b at 0')
  expect.falsy(limiter:record('a', 1), 'a at 1')
  expect.falsy(limiter:record('b', 1), 'b at 1')
  expect.equal(limiter:suppressedCount 'a', 1, "a's suppressed count")
  expect.equal(limiter:suppressedCount 'b', 1, "b's suppressed count")
end)

spec('the limiter evicts the least recently recorded key when it is full', function()
  local limiter = errors.newLimiter(5, 2)

  limiter:record('a', 0)
  limiter:record('b', 0)
  limiter:record('a', 1)
  -- 'c' is the third key and the bound is two, so the least recently recorded
  -- goes. That is 'b': 'a' was recorded again after it.
  limiter:record('c', 1)

  expect.falsy(limiter:record('a', 2), 'a, which is still tracked')
  expect.truthy(limiter:record('b', 2), 'b, which was evicted')
end)

spec('the limiter rejects a key that is not a string', function()
  local limiter = errors.newLimiter()

  expect.raises(function()
    limiter:record(7, 0)
  end, 'a string', 'record')
end)

spec('the limiter rejects a time that is not a number', function()
  local limiter = errors.newLimiter()

  expect.raises(function()
    limiter:record('a', 'now')
  end, 'told the time', 'record')
end)

spec("hands a reported error to the configuration's lovr.lunerror", function()
  fresh()
  local seen = {}
  local previous = lovr.lunerror

  lovr.lunerror = function(event)
    seen[#seen + 1] = event
  end
  errors.handle('it broke', 'a traceback', 0)
  errors.handle('it broke', 'a traceback', 1)
  lovr.lunerror = previous

  expect.equal(#seen, 1, 'lunerror call count')
  expect.equal(seen[1].message, 'it broke', 'the message')
  expect.equal(seen[1].traceback, 'a traceback', 'the traceback')
end)

spec('a lovr.lunerror that raises does not take the report with it', function()
  local reports = fresh()
  local previous = lovr.lunerror

  lovr.lunerror = function()
    error('the handler said no')
  end
  local reported = errors.handle('it broke', 'a traceback', 0)
  lovr.lunerror = previous

  expect.truthy(reported, 'handle')
  expect.equal(#reports, 1, 'report count')
end)

spec('install replaces lovr.errhand and uninstall puts it back', function()
  fresh()
  local previous = lovr.errhand

  expect.truthy(errors.install(clock().read), 'install')
  expect.truthy(errors.isInstalled(), 'isInstalled')
  expect.falsy(lovr.errhand == previous, 'lovr.errhand while installed')

  expect.truthy(errors.uninstall(), 'uninstall')
  expect.falsy(errors.isInstalled(), 'isInstalled after uninstall')
  expect.equal(lovr.errhand, previous, 'lovr.errhand after uninstall')
end)

spec('installing twice does nothing the second time', function()
  fresh()

  errors.install(clock().read)
  local handler = lovr.errhand
  expect.falsy(errors.install(clock().read), 'the second install')
  expect.equal(lovr.errhand, handler, 'lovr.errhand')

  errors.uninstall()
end)

spec('uninstalling twice does nothing the second time', function()
  fresh()

  errors.install(clock().read)
  expect.truthy(errors.uninstall(), 'the first uninstall')
  expect.falsy(errors.uninstall(), 'the second uninstall')
end)

spec('the installed handler reports through the rate limiter', function()
  local reports = fresh()
  local time = clock()

  errors.install(time.read)
  -- From one call site, and that matters: the handler computes the traceback
  -- itself and the traceback is part of the rate-limit key, so the same message
  -- raised from two lines is two keys. An error raised every frame comes from
  -- one line, which is the case this stands in for.
  for _ = 1, 2 do
    lovr.errhand 'it broke'
  end
  errors.uninstall()

  -- Two calls, one report: the second was suppressed, which is the whole point
  -- of an error raised every frame not filling the display.
  expect.equal(#reports, 1, 'report count')
end)

spec('the installed handler hands the loop decision to the previous one', function()
  fresh()
  local previous = lovr.errhand
  local loop = function() end

  lovr.errhand = function()
    return loop
  end
  errors.install(clock().read)
  local result = lovr.errhand 'it broke'
  errors.uninstall()
  lovr.errhand = previous

  expect.equal(result, loop, 'what the handler returned')
end)

spec('install registers a teardown hook that uninstalls', function()
  fresh()
  local previous = lovr.errhand

  errors.install(clock().read)
  local found = false
  for _, name in ipairs(teardown.pending()) do
    if name == 'mullion.error' then
      found = true
    end
  end
  expect.truthy(found, 'the registered hook')

  teardown.run()
  expect.falsy(errors.isInstalled(), 'isInstalled after teardown')
  expect.equal(lovr.errhand, previous, 'lovr.errhand after teardown')
end)

spec('uninstall forgets what was rate-limited', function()
  local reports = fresh()

  errors.install(clock().read)
  errors.handle('it broke', 'a traceback', 0)
  errors.uninstall()
  errors.handle('it broke', 'a traceback', 0)

  -- The same error within the window, and reported twice: the limiter the
  -- second went through is a fresh one, so a reload does not inherit the old
  -- state's suppression and silently swallow the first error of the new one.
  expect.equal(#reports, 2, 'report count')
end)

spec('requiring twice returns the same module', function()
  expect.equal(require 'mullion.error', errors, 'the module')
end)

return spec
