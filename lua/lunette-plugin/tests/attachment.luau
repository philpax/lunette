-- Covers the native plugin attachment as Lua sees it: cancelled loads, request ordering, stale effects, a
-- provider reload fanning out to its dependents, instance state and diagnostics, and what a removed instance
-- retains.
local testing = require '@testing'
local expect = testing.expect
local plugin = require('@lunette').plugin

local test = testing.suite()

local function empty()
  return {}
end

test('an initializer raising because its own activation was cancelled ends the load as cancelled', function()
  local runtime = plugin.runtime()
  local instance
  local definition = plugin.define({}, {}, function(context)
    instance:disable()
    context:effect(function()
      return function() end
    end)
    return {}
  end, 'cancelled initializer')
  instance = runtime:use(definition, {})
  instance:enable()
  expect.equal(instance:state(), 'inactive', 'the cancelled load')
  expect.equal(instance:diagnostic(), nil, 'the diagnostic of the cancelled load')
  runtime:close()
end)

test('requests apply in order and fail at the call that made them', function()
  local runtime = plugin.runtime()
  local removed = runtime:use(plugin.define({}, {}, empty, 'removed'), {})
  removed:dispose()
  expect.equal(removed:state(), 'removed', 'the disposed idle instance')
  local target = runtime:use(plugin.define({}, {}, empty, 'target'), {})
  local observed = {}
  local host = runtime:use(
    plugin.define({}, {}, function()
      observed.removed = pcall(function()
        removed:enable()
      end)
      target:enable()
      target:dispose()
      observed.retired = pcall(function()
        target:enable()
      end)
      return {}
    end, 'host'),
    {}
  )
  host:enable()
  expect.equal(observed.removed, false, 'a request for a removed instance is accepted')
  expect.equal(observed.retired, false, 'a retired instance accepts enable')
  expect.equal(host:state(), 'active', 'the loading instance whose requests were rejected')
  expect.equal(target:state(), 'removed', 'the target of enable followed by dispose')
  runtime:close()
  expect.raises(function()
    host:enable()
  end, nil, 'a request to a closed runtime')
end)

test('disposing an effect whose instance was removed or whose runtime closed does nothing', function()
  local released = 0
  local effects = {}
  local definition = plugin.define({}, {}, function(context)
    table.insert(
      effects,
      context:effect(function()
        return function()
          released += 1
        end
      end)
    )
    return {}
  end, 'stale effects')
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, {})
  instance:enable()
  instance:dispose()
  expect.equal(instance:state(), 'removed', 'the disposed instance')
  expect.equal(released, 1, 'the releases after the disposal')
  effects[1]:dispose()
  local closed = plugin.runtime()
  closed:use(definition, {}):enable()
  closed:close()
  expect.equal(released, 2, 'the releases after the close')
  effects[2]:dispose()
  expect.equal(released, 2, 'the releases after disposing the stale effects')
  runtime:close()
end)

test('a provider reload drains and reloads every dependent in one drain', function()
  local token = plugin.contract('audit/fan-out', 1)
  local runtime = plugin.runtime()
  local provider = runtime:use(
    plugin.define({}, { service = token }, function()
      return { service = {} }
    end, 'fan-out provider'),
    {}
  )
  provider:enable()
  local loads = 0
  local consumer = plugin.define({ service = token }, {}, function()
    loads += 1
    return {}
  end, 'fan-out consumer')
  local consumers = {}
  for index = 1, 200 do
    consumers[index] = runtime:use(consumer, {})
    consumers[index]:enable()
  end
  expect.equal(loads, 200, 'the first loads')
  provider:reload {}
  expect.equal(loads, 400, 'the loads after the provider reload')
  for index, instance in consumers do
    expect.equal(instance:state(), 'active', 'consumer ' .. index)
  end
  runtime:close()
end)

test('instance state and diagnostics name the definition, and a waiting consumer is not reported', function()
  local token = plugin.contract('audit/diagnostics', 1)
  local runtime = plugin.runtime()
  local failing = runtime:use(
    plugin.define({}, {}, function()
      error 'audit initializer failure'
    end, 'audit failing plugin'),
    {}
  )
  failing:enable()
  expect.equal(failing:state(), 'failed', 'the failed load')
  local diagnostic = failing:diagnostic() or ''
  expect.truthy(string.find(diagnostic, 'audit failing plugin', 1, true), diagnostic)
  expect.truthy(string.find(diagnostic, 'audit initializer failure', 1, true), diagnostic)
  local reports = testing.takeReports()
  expect.equal(#reports, 1, table.concat(reports, '\n'))
  expect.truthy(
    string.find(reports[1], 'plugin load: audit failing plugin (instance ', 1, true) == 1
      and string.find(reports[1], 'audit initializer failure', 1, true),
    reports[1]
  )
  local waiting = runtime:use(
    plugin.define({ service = token }, {}, function()
      return {}
    end, 'audit waiting consumer'),
    {}
  )
  waiting:enable()
  expect.equal(waiting:state(), 'inactive', 'the waiting consumer')
  local reason = waiting:diagnostic() or ''
  expect.truthy(string.find(reason, 'waiting for a provider of audit/diagnostics@1', 1, true), reason)
  runtime
    :use(
      plugin.define({}, { service = token }, function()
        return { service = {} }
      end, 'audit provider'),
      {}
    )
    :enable()
  expect.equal(waiting:state(), 'active', 'the published consumer')
  expect.equal(waiting:diagnostic(), nil, 'the diagnostic of the published consumer')
  runtime:close()
  expect.equal(waiting:state(), 'removed', 'the consumer after close')
end)

test('a removed instance releases its configuration while its runtime lives', function()
  local witness = setmetatable({}, { __mode = 'v' })
  local runtime = plugin.runtime()
  local definition = plugin.define({}, {}, function(context, config)
    context:effect(function()
      return function()
        assert(config ~= nil)
      end
    end)
    return {}
  end);
  (function()
    local payload = {}
    witness.payload = payload
    local instance = runtime:use(definition, payload)
    instance:enable()
    instance:dispose()
  end)()
  testing.collect()
  expect.equal(witness.payload, nil, 'the configuration of the removed instance')
  runtime:close()
end)

return test
