-- Covers how a plugin failure is reported: an initializer's error keeps its position and traceback, a
-- schema mismatch names both schemas, and a provider awaiting quarantine keeps serving until it unloads.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'

local test = testing.suite()

test('an initializer error is reported with its own position and traceback', function()
  local function raiseFromInitializer()
    error 'initializer position failure'
  end
  local runtime = plugin.runtime()
  runtime
    :use(
      plugin.define {
        name = 'failing',
        init = function()
          raiseFromInitializer()
        end,
      },
      {}
    )
    :enable()
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the reports')
  local report = reports[1]
  expect.truthy(report:find '^plugin load: failing %(instance ', 'the report names the definition: ' .. report)
  expect.truthy(
    report:find '@lunette%-plugin/tests/failures%.luau:%d+: initializer position failure',
    'the error keeps the position it was raised at: ' .. report
  )
  expect.truthy(report:find('raiseFromInitializer', 1, true), 'the traceback reaches the raising function')
  local line = report:match '[^\n]*initializer position failure[^\n]*'
  expect.falsy(line:find('adapter', 1, true), 'the adapter adds no position: ' .. line)
  runtime:close()
end)

test('requiring an undeclared capability raises at the caller with the capability named', function()
  local undeclared = plugin.capability { name = 'local/positions-undeclared', schema = 1 }
  local message
  local runtime = plugin.runtime()
  runtime
    :use(
      plugin.define {
        name = 'probe',
        init = function(context)
          message = expect.raises(function()
            context:require(undeclared)
          end)
        end,
      },
      {}
    )
    :enable()
  expect.truthy(message:find '^@lunette%-plugin/tests/failures%.luau:%d+: ', 'the position: ' .. message)
  expect.truthy(
    message:find('plugin require: capability local/positions-undeclared@1 is not declared', 1, true),
    message
  )
  runtime:close()
end)

test('a consumer of another schema than its provider publishes waits, and its diagnostic says why', function()
  local first = plugin.capability { name = 'local/schema-mismatch', schema = 1 }
  local second = plugin.capability { name = 'local/schema-mismatch', schema = 2 }
  local loaded = false
  local runtime = plugin.runtime()
  runtime
    :use(
      plugin.define {
        name = 'provider',
        provides = { service = first },
        init = function(_context, _config, publish)
          publish:provide(first, {})
        end,
      },
      {}
    )
    :enable()
  local consumer = runtime:use(
    plugin.define {
      name = 'consumer',
      requires = { service = second },
      init = function()
        loaded = true
      end,
    },
    {}
  )
  consumer:enable()
  expect.falsy(loaded, 'the consumer loaded')
  expect.equal(consumer:state(), 'inactive', 'the consumer')
  local diagnostic = tostring(consumer:diagnostic())
  expect.truthy(diagnostic:find('local/schema-mismatch', 1, true), diagnostic)
  expect.truthy(diagnostic:find('requires', 1, true), diagnostic)
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the reports')
  expect.truthy(reports[1]:find(diagnostic, 1, true), 'the report carries the diagnostic: ' .. reports[1])
  runtime:close()
end)

test('a provider whose disposal failed keeps serving its consumers until it unloads', function()
  local echo = plugin.capability { name = 'local/quarantine-pending-echo', schema = 1 }
  local released = {}
  local kept
  local runtime = plugin.runtime()
  local provider = runtime:use(
    plugin.define {
      name = 'provider',
      provides = { echo = echo },
      init = function(context, _config, publish)
        local doomed = context:effect(function()
          return function()
            error('the doomed inverse fails', 0)
          end
        end)
        publish:provide(echo, {
          ping = function(_self, value)
            return value
          end,
          dropDoomed = function(_self)
            doomed:dispose()
          end,
        })
      end,
    },
    {}
  )
  provider:enable()
  local consumer = runtime:use(
    plugin.define {
      name = 'consumer',
      requires = { echo = echo },
      init = function(context)
        local service = context:require(echo)
        kept = service
        context:effect(function()
          return function()
            released[#released + 1] = service:ping 'released'
          end
        end)
      end,
    },
    {}
  )
  consumer:enable()

  expect.raises(function()
    kept:dropDoomed()
  end, 'the doomed inverse fails', 'the failed disposal')
  expect.equal(provider:state(), 'active', 'a provider awaiting quarantine stays active')
  expect.equal(kept:ping 'still served', 'still served', 'a provider awaiting quarantine keeps serving')

  provider:disable()
  expect.equal(consumer:state(), 'inactive', 'the consumer unloads cleanly')
  expect.equal(released[1], 'released', 'the consumer inverse reached the provider')
  expect.equal(provider:state(), 'quarantined', 'the provider once it has unloaded')
  -- The failed disposal raised to its caller and is not reported again. The consumer, still enabled, now
  -- waits on a quarantined provider.
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the reports')
  expect.truthy(reports[1]:find('is quarantined after a cleanup failure', 1, true), reports[1])
  runtime:close()
end)

return test
