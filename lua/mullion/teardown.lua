-- The teardown registry.
--
-- A soft reload discards the Lua state and re-runs the configuration
-- (docs/lua-api.md#reload). Timers, signal connections, coroutines, and
-- stashed handles from the state being discarded outlive it unless something
-- takes them down, and CONTRIBUTING.md makes a module that leaks one across a
-- reload a defect. A module registers a hook, and reload runs them.
--
-- `lunette.reload()` is the caller. It runs the hooks first, then clears
-- the state, so a hook still has the modules and callbacks it is tearing
-- down.
--
-- Hooks are keyed by name and run in reverse registration order. A module
-- tears down ahead of whatever it depends on. `mullion.panel` registered
-- after `mullion.signal`, because it requires it, and runs first, so it
-- still has signals to disconnect from when it does.

local teardown = {}

type Hook = () -> ()
type Failure = { name: string, message: string }

-- Every registered hook, as `{ [name] = run }`, and the order the names are
-- first registered in.
--
-- The module body re-creates the tables on each run. A reload that re-runs
-- every module starts from an empty registry; the previous registry does not
-- survive.
local hooks: { [string]: Hook } = {}
local order: { string } = {}

-- Where a hook that raised is reported.
--
-- Replaceable. The reload routes it wherever it routes everything else, and a
-- spec captures it. The default logs the message, which the host routes to
-- its own diagnostics.
function teardown.report(message: string)
  -- `lovr.log` is a callback that a configuration may have cleared.
  -- `teardown.report` does not raise an error when logging is unavailable.
  local log = lovr.log
  if log then
    log(message, 'error', 'mullion.teardown')
  end
end

-- Registers `run` under `name`, replacing any hook already registered under it.
--
-- Replacement makes a module safe to `require` twice. A module body that runs
-- a second time registers the same name again, and there is still one hook.
-- A reload then runs one copy of a teardown, and no hook stays registered
-- against state that has gone.
--
-- The name is the module's own path, `mullion.signal`. Two modules cannot
-- collide, and a report names the module, not an index.
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

-- Removes the hook registered under `name` and returns whether it removed one.
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

-- The registered names in reverse registration order, the order `run` calls
-- them in.
function teardown.pending(): { string }
  local names: { string } = {}
  for index = #order, 1, -1 do
    names[#names + 1] = order[index]
  end
  return names
end

-- Runs every hook in reverse registration order and empties the registry.
--
-- Each hook runs under `xpcall`, so one raising an error does not stop the
-- others. CONTRIBUTING.md forbids swallowing an error; the catch reports the
-- error through `teardown.report`, and does not lose it. Reload has to
-- complete either way, and a half-torn-down state is worse than a reported
-- failure.
--
-- Returns the failures, as `{ { name, message } }`, and reports each through
-- `teardown.report`. A caller that acts on the failures reads the return
-- value. A caller that does nothing with them still gets the report.
--
-- The registry is emptied whether or not a hook raised. A failed hook does
-- not get a second run: leaving it registered would run it again at the next
-- reload against state that has gone.
function teardown.run(): { Failure }
  local names = teardown.pending()
  -- The name list is captured first, and the registry is emptied when the
  -- run starts. A hook is free to register another during a run; that hook
  -- belongs to the state being built, not to the state being discarded.
  local registered = hooks
  hooks = {}
  order = {}

  local failures: { Failure } = {}
  for _, name in ipairs(names) do
    local run = registered[name]
    if not run then
      -- The order and the registry are written together, so a name in one and
      -- not the other is a defect in this module, not a state to skip.
      local message = 'the order names it and the registry does not'
      failures[#failures + 1] = { name = name, message = message }
      teardown.report("the hook '" .. name .. "' failed: " .. message)
    else
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
