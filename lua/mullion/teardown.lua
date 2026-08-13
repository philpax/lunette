-- The teardown registry.
--
-- A soft reload discards the Lua state and re-runs the configuration
-- (docs/lua-api.md#reload). Timers, signal connections, coroutines, and stashed
-- handles from the state being discarded outlive it unless something takes them
-- down, and CONTRIBUTING.md makes a module that leaks one across a reload a
-- defect. This is what makes that checkable rather than aspirational: a module
-- registers a hook, and reload runs them.
--
-- `lunette.reload()` is the caller, and runs the hooks before it clears
-- anything, so a hook still has the modules and callbacks it is tearing down.
-- This is the registry and the contract.
--
-- Hooks are keyed by name and run in reverse registration order, so a module
-- tears down before whatever it depends on: `mullion.panel` registered after
-- `mullion.signal` because it requires it, and runs before it, so it still has
-- signals to disconnect from when it does.

local teardown = {}

type Hook = () -> ()
type Failure = { name: string, message: string }

-- Every registered hook, as `{ [name] = run }`, and the order the names were
-- first registered in.
--
-- Rebuilt when this file runs, which is what makes a reload that re-runs every
-- module start from an empty registry rather than from the old state's.
local hooks: { [string]: Hook } = {}
local order: { string } = {}

-- Where a hook that raised is reported.
--
-- Replaceable, so that Phase 7's reload can route it wherever it routes
-- everything else, and so that a spec can capture it rather than printing it.
-- The default logs the message, which the host routes to its own diagnostics.
function teardown.report(message: string)
  lovr.log(message, 'error', 'mullion.teardown')
end

-- Registers `run` under `name`, replacing any hook already registered under it.
--
-- Replacing rather than appending is what makes a module safe to `require`
-- twice: a module body that runs a second time registers the same name again
-- and there is still one hook, so a reload does not run two copies of a
-- teardown or leave one of them registered against state that has gone.
--
-- The name is the module's own path — `mullion.signal` — so that two modules
-- cannot collide and a report names the module rather than an index.
function teardown.register(name: string, run: Hook)
  if type(name) ~= 'string' then
    error('mullion.teardown: a hook is named by a string, not a ' .. type(name), 2)
  end
  if type(run) ~= 'function' then
    error("mullion.teardown: the hook '" .. name .. "' is not a function", 2)
  end

  if hooks[name] == nil then
    order[#order + 1] = name
  end
  hooks[name] = run
end

-- Removes the hook registered under `name`, reporting whether there was one.
function teardown.unregister(name: string): boolean
  if hooks[name] == nil then
    return false
  end

  hooks[name] = nil
  for index = 1, #order do
    if order[index] == name then
      table.remove(order, index)
      break
    end
  end
  return true
end

-- The names registered, in reverse registration order: the order `run` will
-- call them in.
function teardown.pending(): { string }
  local names: { string } = {}
  for index = #order, 1, -1 do
    names[#names + 1] = order[index]
  end
  return names
end

-- Runs every hook in reverse registration order and empties the registry.
--
-- Each runs under `xpcall`, so one raising does not stop the others. That is a
-- deliberate exception to CONTRIBUTING.md's rule against swallowing an error:
-- the error is reported rather than swallowed, and a half-torn-down state is
-- worse than a reported failure, because reload has to complete either way.
--
-- Returns the failures, as `{ { name, message } }`, as well as reporting each
-- through `teardown.report`. The return is for a caller that wants to act on
-- them; the report is so that a caller that does not still says something.
--
-- The registry is emptied whether or not a hook raised. A hook that failed has
-- already had its chance, and leaving it registered would run it again at the
-- next reload against state that has gone.
function teardown.run(): { Failure }
  local names = teardown.pending()
  -- Taken before the registry is emptied, and emptied before the first hook
  -- runs: a hook is free to register another, and one registered during a run
  -- belongs to the state being built rather than to the one being discarded.
  local registered = hooks
  hooks = {}
  order = {}

  local failures: { Failure } = {}
  for _, name in ipairs(names) do
    local run = registered[name]
    if run then
      local raised: string?
      local ok = xpcall(run, function(value): string
        raised = debug.traceback(tostring(value), 2)
        return raised
      end)
      if not ok then
        local message = tostring(raised)
        failures[#failures + 1] = { name = name, message = message }
        teardown.report("the hook '" .. name .. "' failed: " .. message)
      end
    end
  end

  return failures
end

return teardown
