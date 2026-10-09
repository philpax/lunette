-- Covers inverse failures, resource authority during explicit disposal, and requests queued from an inverse.
local testing = require '@testing'
local expect = testing.expect
local plugin = require('@lunette').plugin

local test = testing.suite()

local function expectReports(count, needle, context)
  local reports = testing.takeReports()
  expect.equal(#reports, count, context .. ': ' .. table.concat(reports, '\n'))
  for _, report in reports do
    expect.truthy(string.find(report, needle, 1, true), context .. ': ' .. report)
  end
end

test('an inverse failing in an explicit disposal quarantines its instance and keeps its reservation', function()
  local token = plugin.contract('audit/explicit', 1)
  local runtime = plugin.runtime()
  local loads = 0
  local handle
  local remainingReleased = 0
  local payload = { released = false }
  local definition = plugin.define({}, { service = token }, function(context, config)
    loads += 1
    context:effect(function()
      return function()
        remainingReleased += 1
      end
    end)
    handle = context:effect(function()
      return function()
        config.payload.released = true
        error 'inverse failed explicit'
      end
    end)
    return { service = 42 }
  end)
  local instance = runtime:use(definition, { payload = payload })
  instance:enable()
  expect.raises(function()
    handle:dispose()
  end, 'inverse failed explicit', 'the explicit disposal')
  expect.truthy(payload.released, 'the failing inverse ran')
  expect.raises(function()
    instance:enable()
  end, nil, 'enabling the quarantined instance')
  expect.equal(loads, 1, 'the cleanup failure allows no retry')
  instance:disable()
  expect.equal(instance:state(), 'quarantined', 'the instance after its cleanup failure')
  expect.truthy(
    string.find(instance:diagnostic() or '', 'inverse failed explicit', 1, true),
    'the quarantine diagnostic names its cause: ' .. tostring(instance:diagnostic())
  )
  local duplicate = runtime:use(definition, {})
  expect.raises(function()
    duplicate:enable()
  end, nil, 'the cleanup failure keeps its reservation')
  expectReports(0, '', 'the reported failures')
  runtime:close()
  expect.equal(remainingReleased, 1, 'the quarantine runs the remaining inverse')
end)

test('the pending inverses of a consumer run once, before its provider is cleaned up', function()
  local runtime = plugin.runtime()
  local token = plugin.contract('audit/pending', 1)
  local events = {}
  local resource = { alive = true }
  local broken
  local consumer = plugin.define({ service = token }, {}, function(context)
    context:effect(function()
      return function()
        local service = context:services().service
        assert(service == resource and service.alive, 'provider unavailable during pending inverse')
        table.insert(events, 'A')
      end
    end)
    broken = context:effect(function()
      return function()
        table.insert(events, 'B')
        error 'pending cleanup failure'
      end
    end)
    return {}
  end)
  local provider = plugin.define({}, { service = token }, function(context)
    context:effect(function()
      return function()
        table.insert(events, 'P')
        resource.alive = false
      end
    end)
    return { service = resource }
  end)
  runtime:use(provider, {}):enable()
  runtime:use(consumer, {}):enable()
  assert(broken ~= nil, 'consumer not initialized')
  expect.raises(function()
    broken:dispose()
  end, 'pending cleanup failure', 'the failing disposal')
  expect.equal(table.concat(events, ','), 'B', 'the events after the failing disposal')
  runtime:close()
  expect.equal(table.concat(events, ','), 'B,A,P', 'the pending inverse runs once before provider cleanup')
end)

test('a reentrant inverse failing in a cancelled acquisition quarantines the original activation', function()
  local runtime = plugin.runtime()
  local dependency = plugin.contract('audit/inverse-dependency', 1)
  local output = plugin.contract('audit/inverse-output', 1)
  local events = {}
  local providerAlive = true
  runtime
    :use(
      plugin.define({}, { service = dependency }, function(context)
        context:effect(function()
          return function()
            table.insert(events, 'provider')
            providerAlive = false
          end
        end)
        return { service = {} }
      end),
      {}
    )
    :enable()
  local context
  local instance
  local loads = 0
  local definition = plugin.define({ dependency = dependency }, { service = output }, function(current)
    loads += 1
    context = current
    current:effect(function()
      return function()
        assert(providerAlive and current:services().dependency ~= nil, 'dependency lost before old cleanup')
        table.insert(events, 'remaining')
      end
    end)
    return { service = {} }
  end)
  instance = runtime:use(definition, {})
  instance:enable()
  local inverseCalls = 0
  local function inverse()
    inverseCalls += 1
    instance:reload {}
    runtime:drain()
    table.insert(events, 'broken')
    error 'reentrant inverse failure'
  end
  expect.raises(function()
    context:effect(function()
      instance:reload {}
      return inverse
    end)
  end, nil, 'the cancelled acquisition')
  expect.equal(table.concat(events, ','), 'broken,remaining', 'the cancelled activation inverse order')
  expect.raises(function()
    instance:enable()
  end, nil, 'enabling the quarantined instance')
  expect.raises(function()
    instance:reload {}
  end, nil, 'reloading the quarantined instance')
  instance:dispose()
  runtime:drain()
  expect.equal(loads, 1, 'the failed old inverse permits no replacement activation')
  expect.equal(inverseCalls, 1, 'the failed inverse is not retried')
  expect.falsy(context:active(), 'the failed allocation remains published')
  local duplicate = runtime:use(definition, {})
  expect.raises(function()
    duplicate:enable()
  end, nil, 'the failed cleanup keeps its provided reservation')
  expect.truthy(providerAlive, 'the failed cleanup keeps its dependency')
  expectReports(1, 'reentrant inverse failure', 'the reported failures')
  runtime:close()
  expect.equal(table.concat(events, ','), 'broken,remaining,provider', 'the shutdown cleanup order')
  expect.equal(inverseCalls, 1, 'shutdown does not retry a failed inverse')
end)

test(
  'an explicit successful disposal during load revokes resource authority while it runs, then restores the live owner',
  function()
    local runtime = plugin.runtime()
    local childCalls = 0
    local childDefinition = plugin.define({}, {}, function()
      childCalls += 1
      return {}
    end)
    local acquired = 0
    local attempts
    local disposable
    local definition = plugin.define({}, {}, function(context)
      disposable = context:effect(function()
        return function()
          attempts = {
            active = context:active(),
            effect = pcall(function()
              context:effect(function()
                acquired += 1
                return function()
                  acquired -= 1
                end
              end)
            end),
            child = pcall(function()
              context:child(childDefinition, {}):enable()
            end),
          }
        end
      end)
      disposable:dispose()
      assert(
        attempts ~= nil and not attempts.active and not attempts.effect and not attempts.child,
        'explicit inverse retains resource authority'
      )
      assert(acquired == 0 and childCalls == 0, 'explicit inverse ran acquisition')
      assert(context:active(), 'successful explicit inverse revoked owner permanently')
      context:effect(function()
        acquired += 1
        return function()
          acquired -= 1
        end
      end)
      context:child(childDefinition, {}):enable()
      return {}
    end)
    runtime:use(definition, {}):enable()
    assert(attempts ~= nil, 'initializer cleanup assertions did not run')
    expect.truthy(acquired == 1 and childCalls == 1, 'the successful cleanup restores the live owner')
    runtime:close()
    expect.equal(acquired, 0, 'no explicitly cleaned resource outlives close')
  end
)

test('a caught nested inverse failure after load leaves its owner cleanup-only', function()
  local runtime = plugin.runtime()
  local context
  local outer
  local inverseCalls = 0
  local remainingCalls = 0
  local acquisitions = 0
  local childLoads = 0
  local child = plugin.define({}, {}, function()
    childLoads += 1
    return {}
  end)
  local instance = runtime:use(
    plugin.define({}, {}, function(owner)
      context = owner
      owner:effect(function()
        return function()
          remainingCalls += 1
        end
      end)
      local inner = owner:effect(function()
        return function()
          inverseCalls += 1
          error 'nested inverse failure'
        end
      end)
      outer = owner:effect(function()
        return function()
          inverseCalls += 1
          local ok, failure = pcall(function()
            inner:dispose()
          end)
          expect.falsy(ok, 'the nested disposal')
          expect.truthy(string.find(tostring(failure), 'nested inverse failure', 1, true), 'the caught failure')
        end
      end)
      return {}
    end),
    {}
  )
  instance:enable()
  outer:dispose()
  expect.equal(inverseCalls, 2, 'each nested inverse runs once')
  expect.falsy(context:active(), 'the owner authority after nested disposal')
  expect.raises(function()
    context:effect(function()
      acquisitions += 1
      return function() end
    end)
  end, nil, 'a quarantined owner acquires no resource')
  expect.raises(function()
    context:child(child, {}):enable()
  end, nil, 'a quarantined owner creates no child')
  expect.raises(function()
    context:checkOwner(context)
  end, nil, 'a quarantined owner registers no caller-owned resource')
  expect.equal(acquisitions, 0, 'no acquisition runs after nested failure')
  expect.equal(childLoads, 0, 'no child loads after nested failure')
  instance:disable()
  expect.equal(instance:state(), 'quarantined', 'the failed activation remains quarantined')
  expect.raises(function()
    instance:enable()
  end, nil, 'a quarantined instance cannot retry')
  runtime:close()
  expect.equal(inverseCalls, 2, 'shutdown repeats no disposed inverse')
  expect.equal(remainingCalls, 1, 'shutdown releases the remaining inverse')
  expectReports(0, '', 'caught explicit failures produce no reports')
end)

test('a caught acquisition failure keeps the loading owner and its nested effect', function()
  local runtime = plugin.runtime()
  local events = {}
  local acquired = 0
  local childLoads = 0
  local childDefinition = plugin.define({}, {}, function()
    childLoads += 1
    return {}
  end)
  runtime
    :use(
      plugin.define({}, {}, function(context)
        local ok = pcall(function()
          context:effect(function()
            context:effect(function()
              acquired += 1
              return function()
                acquired -= 1
                table.insert(events, 'nested')
              end
            end)
            error 'caught acquisition failure'
          end)
        end)
        assert(not ok and context:active(), 'caught acquisition error revoked loading owner')
        context:effect(function()
          acquired += 1
          return function()
            acquired -= 1
            table.insert(events, 'after')
          end
        end)
        context:child(childDefinition, {}):enable()
        return {}
      end),
      {}
    )
    :enable()
  expect.equal(acquired, 2, 'the tracked effects')
  expect.equal(childLoads, 1, 'the valid child')
  runtime:close()
  expect.equal(acquired, 0, 'the effects outliving close')
  expect.equal(table.concat(events, ','), 'after,nested', 'the cleanup order')
end)

test('cleanup reads its services but acquires nothing, and an owner check accepts only the current caller', function()
  local token = plugin.contract('audit/authority', 1)
  local providerContext
  local contexts = {}
  local runtime = plugin.runtime()
  local provider = runtime:use(
    plugin.define({}, { service = token }, function(context)
      providerContext = context
      return { service = 42 }
    end),
    {}
  )
  local cleaned = 0
  local consumer = runtime:use(
    plugin.define({ service = token }, {}, function(context)
      table.insert(contexts, context)
      providerContext:checkOwner(context)
      context:effect(function()
        return function()
          assert(context:services().service == 42, 'retained read failed')
          assert(not pcall(function()
            context:effect(function()
              return function() end
            end)
          end))
          cleaned += 1
        end
      end)
      return {}
    end),
    {}
  )
  provider:enable()
  consumer:enable()
  consumer:reload {}
  expect.equal(#contexts, 2, 'the activations')
  expect.raises(function()
    providerContext:checkOwner(contexts[1])
  end, nil, 'the owner check on the old caller')
  expect.equal(cleaned, 1, 'the cleanup reading its services')
  runtime:close()
  expect.equal(cleaned, 2, 'the cleanups at close')
end)

test('a disable requested from an inverse of the instance being disabled is queued', function()
  local token = plugin.contract('test/reentrant', 1)
  local events = {}
  local instance
  local definition = plugin.define({}, { service = token }, function(context)
    table.insert(events, 'load')
    context:effect(function()
      return function()
        table.insert(events, 'release')
        instance:disable()
      end
    end)
    return { service = {} }
  end)
  local runtime = plugin.runtime()
  instance = runtime:use(definition, {})
  instance:enable()
  instance:disable()
  expect.equal(table.concat(events, ','), 'load,release', 'the events')
  expect.equal(instance:state(), 'inactive', 'the instance')
  runtime:close()
end)

return test
