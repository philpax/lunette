-- Runs the `lua/spec/` suites and reports what failed.
--
-- Discovery is separated from running, and both take their outside world as an
-- argument. `discover` is handed a directory lister; `run` is handed the suites
-- it is to run. Nothing here reaches for `lovr`, so the runner is exercised by
-- its own spec without a filesystem at all.

local suite = require '@spec/suite'

local runner = {}

-- The suffix a spec file's name ends with, and the extension it carries.
local SPEC_SUFFIX = '_spec.lua'

-- Module names for every spec file under `directory`, in sorted order.
-- `filesystem` supplies `list(path)` and `isDirectory(path)`; `prefix` names the
-- corresponding module path.
function runner.discover(filesystem, directory, prefix)
  local names = {}

  local function walk(path, modulePrefix)
    local items = filesystem.list(path)
    table.sort(items)
    for _, item in ipairs(items) do
      local child = path .. '/' .. item
      if filesystem.isDirectory(child) then
        walk(child, modulePrefix .. item .. '/')
      elseif item:sub(-#SPEC_SUFFIX) == SPEC_SUFFIX then
        names[#names + 1] = modulePrefix .. item:sub(1, #item - #'.lua')
      end
    end
  end

  walk(directory, prefix)
  return names
end

-- Requires each named module and returns the suites they hand back.
--
-- A spec file that returns something other than a suite is an error rather than
-- a skip: a file under `lua/spec/` that runs nothing is a file whose coverage
-- was silently lost.
function runner.collect(names)
  local suites = {}
  for _, name in ipairs(names) do
    local collected = require(name)
    if not suite.isSuite(collected) then
      error(name .. ' did not return a spec suite')
    end
    suites[#suites + 1] = collected
  end
  return suites
end

-- Runs every case and returns `{ total, failures }`.
-- Each case is isolated with `xpcall`; `onCaseFinished` runs after each case.
function runner.run(suites, onCaseFinished)
  local results = { total = 0, failures = {} }

  for _, collected in ipairs(suites) do
    for _, case in ipairs(collected.cases) do
      results.total = results.total + 1
      local ok, message = xpcall(case.run, function(raised)
        return debug.traceback(tostring(raised), 2)
      end)
      if not ok then
        results.failures[#results.failures + 1] = {
          suite = collected.name,
          case = case.name,
          message = message,
        }
      end
      if onCaseFinished then
        onCaseFinished()
      end
    end
  end

  return results
end

-- What `run` produced, as one string to print.
function runner.format(results)
  local lines = {}
  for _, failure in ipairs(results.failures) do
    lines[#lines + 1] = 'FAIL ' .. failure.suite .. ': ' .. failure.case
    lines[#lines + 1] = '  ' .. failure.message:gsub('\n', '\n  ')
  end
  lines[#lines + 1] = string.format(
    '%d case%s, %d failure%s',
    results.total,
    results.total == 1 and '' or 's',
    #results.failures,
    #results.failures == 1 and '' or 's'
  )
  return table.concat(lines, '\n')
end

return runner
