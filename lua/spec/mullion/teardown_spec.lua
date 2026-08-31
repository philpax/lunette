-- Covers lua/mullion/teardown.lua.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local teardown = require '@mullion/teardown'

local spec = suite.new 'mullion.teardown'

-- The module's own `report`. The default-report case restores it.
local defaultReport = teardown.report

-- Empties the registry and captures reports, returning the list of messages.
--
-- Every case starts here. The registry is module-level state, and prior cases
-- and other modules have already registered their own hooks.
local function fresh()
  teardown.run()

  local reports = {}
  teardown.report = function(message)
    reports[#reports + 1] = message
  end
  return reports
end

spec('runs hooks in reverse registration order', function()
  fresh()
  local order = {}

  teardown.register('first', function()
    order[#order + 1] = 'first'
  end)
  teardown.register('second', function()
    order[#order + 1] = 'second'
  end)
  teardown.register('third', function()
    order[#order + 1] = 'third'
  end)
  teardown.run()

  expect.equal(table.concat(order, ','), 'third,second,first', 'order')
end)

spec('pending reports the order the hooks will run in', function()
  fresh()

  teardown.register('first', function() end)
  teardown.register('second', function() end)

  local pending = teardown.pending()
  expect.equal(#pending, 2, 'count')
  expect.equal(pending[1], 'second', 'the first to run')
  expect.equal(pending[2], 'first', 'the second to run')
end)

spec('a hook that raises does not prevent the others running', function()
  fresh()
  local ran = {}

  teardown.register('before', function()
    ran[#ran + 1] = 'before'
  end)
  teardown.register('raises', function()
    error 'the hook said no'
  end)
  teardown.register('after', function()
    ran[#ran + 1] = 'after'
  end)
  teardown.run()

  expect.equal(table.concat(ran, ','), 'after,before', 'the hooks that ran')
end)

spec('a hook that raises is reported and returned', function()
  local reports = fresh()

  teardown.register('raises', function()
    error 'the hook said no'
  end)
  local failures = teardown.run()

  expect.equal(#failures, 1, 'failure count')
  expect.equal(failures[1].name, 'raises', 'the failing hook')
  expect.truthy(failures[1].message:find 'the hook said no', 'the message')
  expect.equal(#reports, 1, 'report count')
  expect.truthy(reports[1]:find "'raises'", 'the report names the hook')
end)

spec('a run in which nothing raised reports nothing', function()
  local reports = fresh()

  teardown.register('quiet', function() end)
  local failures = teardown.run()

  expect.equal(#failures, 0, 'failure count')
  expect.equal(#reports, 0, 'report count')
end)

spec('registering the same name twice leaves one hook', function()
  fresh()
  local calls = 0

  teardown.register('once', function()
    calls = calls + 1
  end)
  teardown.register('once', function()
    calls = calls + 1
  end)

  expect.equal(#teardown.pending(), 1, 'pending count')
  teardown.run()
  expect.equal(calls, 1, 'call count')
end)

spec('re-registering a name keeps its place in the order', function()
  fresh()
  local order = {}

  teardown.register('first', function()
    order[#order + 1] = 'first'
  end)
  teardown.register('second', function()
    order[#order + 1] = 'second'
  end)
  teardown.register('first', function()
    order[#order + 1] = 'first again'
  end)
  teardown.run()

  expect.equal(table.concat(order, ','), 'second,first again', 'order')
end)

spec('unregister removes a hook and reports whether there was one', function()
  fresh()
  local calls = 0

  teardown.register('going', function()
    calls = calls + 1
  end)

  expect.truthy(teardown.unregister 'going', 'the first unregister')
  expect.falsy(teardown.unregister 'going', 'the second unregister')
  teardown.run()
  expect.equal(calls, 0, 'call count')
end)

spec('a run empties the registry, so a second run does nothing', function()
  fresh()
  local calls = 0

  teardown.register('once', function()
    calls = calls + 1
  end)
  teardown.run()
  teardown.run()

  expect.equal(calls, 1, 'call count')
  expect.equal(#teardown.pending(), 0, 'pending count')
end)

spec('a hook registered while a run is under way survives the run', function()
  fresh()
  local calls = 0

  teardown.register('registers', function()
    teardown.register('registered during the run', function()
      calls = calls + 1
    end)
  end)
  teardown.run()

  expect.equal(calls, 0, 'calls during the run')
  expect.equal(#teardown.pending(), 1, 'pending after the run')
end)

spec('a hook that raised is not left registered', function()
  fresh()

  teardown.register('raises', function()
    error 'the hook said no'
  end)
  teardown.run()

  expect.equal(#teardown.pending(), 0, 'pending count')
end)

spec('rejects a hook that is not a function', function()
  fresh()

  expect.raises(function()
    teardown.register('bad', 'not a function')
  end, 'is not a function', 'register')
end)

spec('rejects a name that is not a string', function()
  fresh()

  expect.raises(function()
    teardown.register(7, function() end)
  end, 'named by a string', 'register')
end)

-- How many hooks are registered under `name`.
local function pendingCount(name)
  local found = 0
  for _, registered in ipairs(teardown.pending()) do
    if registered == name then
      found = found + 1
    end
  end
  return found
end

spec('the default report logs rather than raising', function()
  fresh()
  teardown.report = defaultReport

  local logged = {}
  local previousLog = lovr.log
  lovr.log = function(message, level, tag)
    logged[#logged + 1] = { message = message, level = level, tag = tag }
  end

  teardown.register('raises', function()
    error 'deliberate'
  end)
  -- `run` reports outside the `xpcall` that guards the hook. A `report` that
  -- raises aborts the reload, because the `xpcall` does not cover the report.
  local ran, raised = pcall(teardown.run)

  lovr.log = previousLog
  teardown.report = function() end

  expect.truthy(ran, 'run with the default report: ' .. tostring(raised))
  expect.equal(#logged, 1, 'the log lines')
  expect.equal(logged[1].level, 'error', 'the level')
  expect.equal(logged[1].tag, 'mullion.teardown', 'the tag')
end)

spec('a module body running twice leaves one hook, not two', function()
  fresh()

  -- A soft reload drops `package.loaded` and re-runs the configuration
  -- (docs/dev/lua-api.md#reload), so a module body runs a second time against a
  -- registry that may still hold what the first run put there. Registering by
  -- name leaves one hook. This spec runs last, so no later case reads the
  -- fresh module table it leaves behind.
  local cached = package.loaded['@mullion/signal']
  package.loaded['@mullion/signal'] = nil
  require '@mullion/signal'
  expect.equal(pendingCount 'mullion.signal', 1, 'hooks after the first body run')

  package.loaded['@mullion/signal'] = nil
  require '@mullion/signal'
  expect.equal(pendingCount 'mullion.signal', 1, 'hooks after the second body run')

  package.loaded['@mullion/signal'] = cached
end)

return spec
