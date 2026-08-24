-- The teardown registry.
--
-- Hooks run in reverse registration order, so a module tears down before its
-- dependencies.

local teardown = {}

type Hook = () -> ()
type Failure = { name: string, message: string }

-- Every registered hook and the order in which names were first registered.
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
-- Hook failures are reported and collected, while other hooks still run.
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
