-- Covers the native runtime cancelling an activation during its initializer and inside an acquisition.
local testing = require '@testing'
local expect = testing.expect
local plugin = require('@lunette').plugin

local test = testing.suite()

test('a provider cancelled and re-enabled during its load publishes only the fresh generation', function()
  local runtime = plugin.runtime()
  local token = plugin.contract('audit/reenable', 1)
  local instance
  local consumer
  local attempts = 0
  local observed = {}
  local provider = plugin.define({}, { service = token }, function(context)
    attempts += 1
    local resource = { attempt = attempts, alive = true }
    context:effect(function()
      return function()
        resource.alive = false
      end
    end)
    if attempts == 1 then
      consumer:enable()
      instance:disable()
      instance:enable()
    end
    return { service = resource }
  end)
  consumer = runtime:use(
    plugin.define({ service = token }, {}, function(context)
      table.insert(observed, context:services().service)
      return {}
    end),
    {}
  )
  instance = runtime:use(provider, {})
  instance:enable()
  expect.equal(attempts, 2, 'the cancelled load is retried')
  expect.equal(#observed, 1, 'the published generations')
  expect.equal(observed[1].attempt, 2, 'the published attempt')
  expect.truthy(observed[1].alive, 'the published resource is alive')
  runtime:close()
end)

test('cancellation is observed at the acquisition boundary, and the rollback context acquires nothing', function()
  local runtime = plugin.runtime()
  local instance
  local released = 0
  local reached = false
  local definition = plugin.define({}, {}, function(context)
    local ok = pcall(function()
      context:effect(function()
        instance:disable()
        return function()
          local acquired = 0
          assert(not context:active(), 'cancelled rollback context remains active')
          assert(not pcall(function()
            context:effect(function()
              acquired += 1
              return function() end
            end)
          end), 'cancelled rollback accepts effects')
          assert(acquired == 0, 'cancelled rollback ran acquisition body')
          assert(not pcall(function()
            context:child(
              plugin.define({}, {}, function()
                return {}
              end),
              {}
            )
          end), 'cancelled rollback accepts children')
          released += 1
        end
      end)
    end)
    assert(not ok, 'cancelled acquisition returned success')
    assert(released == 1, 'returned inverse not rolled back')
    local forbiddenCalls = 0
    assert(not pcall(function()
      context:effect(function()
        forbiddenCalls += 1
        return function() end
      end)
    end))
    assert(forbiddenCalls == 0, 'cancelled context invoked acquisition')
    reached = true
    return {}
  end)
  instance = runtime:use(definition, {})
  instance:enable()
  expect.truthy(reached, 'the initializer boundary assertions ran')
  expect.equal(released, 1, 'the inverse releases')
  runtime:close()
end)

test('a disable during an active acquisition cancels it and releases the old inverses once', function()
  for _, acquisition in { 'effect', 'effectDeferred' } do
    local runtime = plugin.runtime()
    local instance
    local contexts = {}
    local events = {}
    local loads = 0
    local definition = plugin.define({}, {}, function(context)
      loads += 1
      local generation = loads
      contexts[generation] = context
      context:effect(function()
        return function()
          table.insert(events, 'base-' .. generation)
        end
      end)
      return {}
    end)
    instance = runtime:use(definition, {})
    instance:enable()
    expect.raises(function()
      contexts[1][acquisition](contexts[1], function()
        instance:disable()
        expect.falsy(contexts[1]:active(), 'pending cancellation revokes acquisition authority before draining')
        runtime:drain()
        return function()
          table.insert(events, 'acquired-1')
        end
      end)
    end, 'cancelled', 'the active acquisition')
    if acquisition == 'effectDeferred' then
      expect.equal(table.concat(events, ','), 'acquired-1', 'only the cancelled acquisition releases before a drain')
      expect.equal(loads, 1, 'the queued lifecycle work remains deferred')
      runtime:drain()
    end
    expect.equal(table.concat(events, ','), 'acquired-1,base-1', 'the old inverses, once and in reverse order')
    expect.falsy(contexts[1]:active(), 'the old context is active')
    expect.equal(loads, 1, 'the loads')
    runtime:close()
    expect.equal(table.concat(events, ','), 'acquired-1,base-1', 'the inverses at close')
  end
end)

test("a disable during a provider's acquisition drains its consumer before it", function()
  local runtime = plugin.runtime()
  local token = plugin.contract('audit/active-provider', 1)
  local escaped
  local events = {}
  local loads = 0
  local provider = runtime:use(
    plugin.define({}, { service = token }, function(context)
      loads += 1
      local generation = loads
      local resource = { alive = true }
      escaped = context
      context:effect(function()
        return function()
          resource.alive = false
          table.insert(events, 'provider-' .. generation)
        end
      end)
      return { service = resource }
    end),
    {}
  )
  provider:enable()
  local consumer = plugin.define({ service = token }, {}, function(context)
    local dependency = context:services().service
    local generation = loads
    context:effect(function()
      return function()
        assert(
          dependency.alive and context:services().service == dependency,
          'active acquisition released provider before consumer'
        )
        table.insert(events, 'consumer-' .. generation)
      end
    end)
    return {}
  end)
  runtime:use(consumer, {}):enable()
  expect.raises(function()
    escaped:effect(function()
      provider:disable()
      return function()
        table.insert(events, 'acquired-1')
      end
    end)
  end, nil, 'the active acquisition')
  -- The cancelled acquisition is withdrawn at once, and the graph then drains the consumer before the provider.
  expect.equal(table.concat(events, ','), 'acquired-1,consumer-1,provider-1', 'the graph cleanup order')
  runtime:close()
end)

return test
