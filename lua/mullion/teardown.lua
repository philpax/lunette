-- The teardown registry.
--
-- Hooks run in reverse registration order. A module therefore tears down before
-- the modules it depends on.

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
-- Replaceable so the host can route errors and specs can capture them.
-- The default logs the message, which the host routes to its own diagnostics.
function teardown.report(message: string)
  -- Read the callback once because a configuration may clear `lovr.log`.
  local log = lovr.log
  if log then
    log(message, 'error', 'mullion.teardown')
  end
end

-- Registers `run` under `name`, replacing any hook already registered under it.
--
-- Replacing rather than appending keeps repeated `require` calls from leaving
-- duplicate teardown hooks against discarded state.
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
-- Each runs under `xpcall`, so one raising does not stop the others. The error
-- is reported rather than swallowed, because reload must finish tearing down the
-- discarded state.
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
    if not run then
      -- The order and the registry are written together, so a name in one and
      -- not the other is a defect in this module rather than a state to skip.
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
