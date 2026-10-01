-- Runs the `lua/spec/` suites and reports what failed.
--
-- The standard library is Lua, and the workspace's checks compile Rust, so
-- nothing else in the tree would run this code. `crates/lunette/tests/
-- lua_spec.rs` runs it inside the binary, where a LuaJIT and a
-- `lovr.filesystem` are available. The devshell ships no standalone
-- interpreter. The specs are required through a mount on LÖVR's virtual
-- filesystem, not the process's.
--
-- Discovery is separated from running, and each takes its outside world as an
-- argument. `discover` takes a directory lister; `run` takes the suites to
-- run. The runner never requires `lovr`, so its own spec exercises it with a
-- fake filesystem.

local suite = require '@spec/suite'

local runner = {}

local SPEC_SUFFIX = '_spec.lua'

-- Module names for every spec file under `directory`, in sorted order.
--
-- `filesystem` is a table of `list(path)`, returning the names directly inside
-- a directory, and `isDirectory(path)`. `lovr.filesystem` supplies both under
-- different names. The fixture adapts it, so this stays testable against a
-- table of strings.
--
-- `prefix` is the module path `directory` is reached by, with its trailing
-- slash: `@spec/mullion/` for `@spec/mullion`.
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
-- A spec file that returns something other than a suite is an error, not a
-- skip: a file under `lua/spec/` that runs nothing loses its coverage
-- silently.
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

-- Runs every case of every suite and returns what happened.
--
-- The result is `{ total = n, failures = { { suite, case, message } } }`. Each
-- case runs under `xpcall` with a traceback. One case raising must not stop
-- the rest: a run that reports every failure is one round of fixing, and a run
-- that reports the first is as many rounds as there are failures.
--
-- `onCaseFinished` is optional and is called with no arguments after each case.
-- The fixture uses it to drain LÖVR's temporary-vector pool, which is otherwise
-- drained at a frame boundary and this run never reaches one.
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
