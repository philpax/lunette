-- Covers how plugin failures are reported, diagnosed, and quarantined.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'

local test = testing.suite()

local function only(reports, needle)
  expect.equal(#reports, 1, table.concat(reports, '\n'))
  expect.truthy(reports[1]:find(needle, 1, true), reports[1])
  return reports[1]
end

test('an initializer error fails its instance and is reported with its position and traceback', function()
  local function raiseFromInitializer()
    error 'initializer position failure'
  end
  local runtime = adapter.runtime()
  local instance = runtime:use(
    adapter.define {
      name = 'failing',
      init = function()
        raiseFromInitializer()
      end,
    },
    {}
  )
  instance:enable()
  expect.equal(instance:state(), 'failed', 'the failed load')
  expect.truthy(
    tostring(testing.diagnostic(runtime, instance)):find('initializer position failure', 1, true),
    'the diagnostic'
  )
  local report = only(testing.takeReports(), 'initializer position failure')
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

test('a consumer waits unreported for a provider, but a schema mismatch is reported', function()
  local first = plugin.capability { name = 'local/schema-mismatch', version = 1 }
  local second = plugin.capability { name = 'local/schema-mismatch', version = 2 }
  local runtime = adapter.runtime()
  local function consumer(capability)
    return runtime:use(adapter.define { name = 'consumer', requires = { capability }, init = function() end }, {})
  end
  local waiting = consumer(first)
  waiting:enable()
  expect.equal(waiting:state(), 'inactive', 'the waiting consumer')
  local reason = tostring(testing.diagnostic(runtime, waiting))
  expect.truthy(reason:find('waiting for a provider of local/schema-mismatch@1', 1, true), reason)
  expect.equal(#testing.takeReports(), 0, 'waiting is not reported')
  runtime
    :use(
      adapter.define {
        name = 'provider',
        provides = { first },
        init = function(_context, _config, publish)
          publish:provide(first, {})
        end,
      },
      {}
    )
    :enable()
  expect.equal(waiting:state(), 'active', 'the consumer once its provider is active')
  expect.equal(testing.diagnostic(runtime, waiting), nil, 'the diagnostic of the active consumer')
  local mismatched = consumer(second)
  mismatched:enable()
  expect.equal(mismatched:state(), 'inactive', 'the mismatched consumer')
  local diagnostic = tostring(testing.diagnostic(runtime, mismatched))
  only(testing.takeReports(), diagnostic)
  runtime:close()
end)

test('a failed disposal quarantines its provider once its consumers have unloaded', function()
  local echo = plugin.capability { name = 'local/quarantine-echo', version = 1 }
  local events = {}
  local kept
  local definition = adapter.define {
    name = 'provider',
    provides = { echo },
    init = function(context, _config, publish)
      context:effect(function()
        return function()
          events[#events + 1] = 'provider remaining'
        end
      end)
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
  }
  local runtime = adapter.runtime()
  local provider = runtime:use(definition, {})
  provider:enable()
  local consumer = runtime:use(
    adapter.define {
      name = 'consumer',
      requires = { echo },
      init = function(context)
        local service = context:require(echo)
        kept = service
        context:effect(function()
          return function()
            events[#events + 1] = 'consumer ' .. service:ping 'served'
          end
        end)
      end,
    },
    {}
  )
  consumer:enable()

  expect.raises(function()
    kept:dropDoomed()
  end, 'the doomed inverse fails', 'the failed disposal raises to its caller')
  expect.equal(provider:state(), 'active', 'a provider awaiting quarantine stays active')
  expect.equal(kept:ping 'still served', 'still served', 'a provider awaiting quarantine keeps serving')
  expect.raises(function()
    provider:requestReload {}
    runtime:drain()
  end, nil, 'a provider awaiting quarantine cannot be reloaded')

  provider:disable()
  expect.equal(consumer:state(), 'inactive', 'the consumer unloads')
  expect.equal(provider:state(), 'quarantined', 'the provider once it has unloaded')
  expect.equal(table.concat(events, ', '), 'consumer served, provider remaining', 'the cleanup order')
  expect.truthy(
    tostring(testing.diagnostic(runtime, provider)):find('the doomed inverse fails', 1, true),
    'the quarantine cause'
  )
  only(testing.takeReports(), 'is quarantined after a cleanup failure')
  expect.raises(function()
    provider:enable()
  end, nil, 'a quarantined instance cannot retry')
  local duplicate = runtime:use(definition, {})
  expect.raises(function()
    duplicate:enable()
  end, nil, 'a quarantined provider keeps its reservation')
  runtime:close()
end)

test('an owner label names the definition, also after the owner unloads', function()
  local held
  local runtime = adapter.runtime()
  local instance = runtime:use(
    adapter.define {
      name = 'labelled-consumer',
      init = function(context)
        held = context
      end,
    },
    {}
  )
  instance:enable()
  expect.equal(plugin.ownerLabel(held), 'labelled-consumer', 'the label')
  instance:disable()
  expect.equal(plugin.ownerLabel(held), 'labelled-consumer', 'the label after the unload')
  runtime:close()
end)

return test
