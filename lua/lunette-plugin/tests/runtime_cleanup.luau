-- Covers the native runtime running inverses outside a rollback: a failing inverse quarantines its instance
-- wherever it fails, an explicit disposal revokes resource authority only while it runs, cleanup keeps the
-- dependency reads it needs, and requests made from inside an inverse are queued.
local testing = require '@testing'
local expect = testing.expect
local plugin = require('@lunette').plugin

local test = testing.suite()

-- Takes the reports and asserts there are `count` of them, each containing `needle`.
local function expectReports(count, needle, context)
  local reports = testing.takeReports()
  expect.equal(#reports, count, context .. ': ' .. table.concat(reports, '\n'))
  for _, report in reports do
    expect.truthy(string.find(report, needle, 1, true), context .. ': ' .. report)
  end
end

-- A failing inverse quarantines its instance whether it fails in a rollback, an explicit disposal, or a plain
-- disable. The inverse runs to its raise, so what it releases before raising stays released.
for _, mode in { 'rollback', 'explicit', 'disable' } do
  test('an inverse failing in ' .. mode .. ' quarantines its instance and keeps its reservation', function()
    local token = plugin.contract('audit/' .. mode, 1)
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
          error('inverse failed ' .. mode)
        end
      end)
      if mode == 'rollback' then
        error 'apply failed'
      end
      return { service = 42 }
    end)
    local instance = runtime:use(definition, { payload = payload })
    instance:enable()
    if mode == 'explicit' then
      -- The explicit disposal's failure is raised to its caller rather than reported.
      expect.raises(function()
        handle:dispose()
      end, 'inverse failed explicit', 'the explicit disposal')
    elseif mode == 'disable' then
      expect.equal(instance:state(), 'active', tostring(instance:diagnostic()))
      instance:disable()
    end
    expect.truthy(payload.released, 'the failing inverse ran')
    expect.raises(function()
      instance:enable()
    end, nil, 'enabling the quarantined instance')
    expect.equal(loads, 1, 'the cleanup failure allows no retry')
    instance:disable()
    expect.equal(instance:state(), 'quarantined', 'the instance after its cleanup failure')
    expect.truthy(
      string.find(instance:diagnostic() or '', 'inverse failed ' .. mode, 1, true),
      'the quarantine diagnostic names its cause: ' .. tostring(instance:diagnostic())
    )
    local duplicate = runtime:use(definition, {})
    expect.raises(function()
      duplicate:enable()
    end, nil, 'the cleanup failure keeps its reservation')
    local reports = testing.takeReports()
    local wanted = ({
      rollback = { 'apply failed', 'inverse failed rollback' },
      explicit = {},
      disable = { 'inverse failed disable' },
    })[mode]
    expect.equal(#reports, #wanted, 'the reported failures: ' .. table.concat(reports, '\n'))
    for index, needle in wanted do
      expect.truthy(string.find(reports[index], needle, 1, true), 'report ' .. index .. ': ' .. reports[index])
    end
    runtime:close()
    expect.equal(remainingReleased, 1, 'the quarantine runs the remaining inverse')
  end)
end

for _, asChild in { false, true } do
  local consumerKind = if asChild then 'a child consumer' else 'a consumer'
  test('the pending inverses of ' .. consumerKind .. ' run once, before its provider is cleaned up', function()
    local runtime = plugin.runtime()
    local token = plugin.contract('audit/pending-' .. tostring(asChild), 1)
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
      if asChild then
        context:child(consumer, {}):enable()
      end
      return { service = resource }
    end)
    runtime:use(provider, {}):enable()
    if not asChild then
      runtime:use(consumer, {}):enable()
    end
    assert(broken ~= nil, 'consumer not initialized')
    expect.raises(function()
      broken:dispose()
    end, 'pending cleanup failure', 'the failing disposal')
    expect.equal(table.concat(events, ','), 'B', 'the events after the failing disposal')
    runtime:close()
    expect.equal(table.concat(events, ','), 'B,A,P', 'the pending inverse runs once before provider cleanup')
  end)
end

for _, explicit in { false, true } do
  local where = if explicit then 'an explicit disposal' else 'a cancelled acquisition'
  test('a reentrant inverse failing in ' .. where .. ' quarantines the original activation', function()
    local runtime = plugin.runtime()
    local dependency = plugin.contract('audit/inverse-dependency-' .. tostring(explicit), 1)
    local output = plugin.contract('audit/inverse-output-' .. tostring(explicit), 1)
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
    if explicit then
      local effect = context:effect(function()
        return inverse
      end)
      expect.raises(function()
        effect:dispose()
      end, 'reentrant inverse failure', 'the explicit disposal')
      effect:dispose()
      -- The reload requested inside the inverse unloads the activation, which runs its remaining inverse and
      -- then quarantines it.
      expect.equal(table.concat(events, ','), 'broken,remaining', 'the explicit failure cleanup order')
    else
      expect.raises(function()
        context:effect(function()
          instance:reload {}
          return inverse
        end)
      end, nil, 'the cancelled acquisition')
      expect.equal(table.concat(events, ','), 'broken,remaining', 'the cancelled activation inverse order')
    end
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
    -- The withdrawn acquisition's failing inverse is reported; the explicit disposal's failure is raised instead.
    expectReports(if explicit then 0 else 1, 'reentrant inverse failure', 'the reported failures')
    runtime:close()
    expect.equal(table.concat(events, ','), 'broken,remaining,provider', 'the shutdown cleanup order')
    expect.equal(inverseCalls, 1, 'shutdown does not retry a failed inverse')
  end)
end

for _, loading in { false, true } do
  for _, broken in { false, true } do
    local title = 'an explicit '
      .. (if broken then 'failing' else 'successful')
      .. ' disposal '
      .. (if loading then 'during load' else 'after load')
      .. ' revokes resource authority while it runs'
      .. (if broken then ' and for good' else ', then restores the live owner')
    test(title, function()
      local runtime = plugin.runtime()
      local childCalls = 0
      local childDefinition = plugin.define({}, {}, function()
        childCalls += 1
        return {}
      end)
      local acquired = 0
      local attempts
      local escaped
      local disposable
      local function disposeAndCheck(context)
        local ok = pcall(function()
          disposable:dispose()
        end)
        assert(ok ~= broken, 'explicit inverse outcome changed')
        assert(
          attempts ~= nil and not attempts.active and not attempts.effect and not attempts.child,
          'explicit inverse retains resource authority'
        )
        assert(acquired == 0 and childCalls == 0, 'explicit inverse ran acquisition')
        if not broken then
          assert(context:active(), 'successful explicit inverse revoked owner permanently')
          context:effect(function()
            acquired += 1
            return function()
              acquired -= 1
            end
          end)
          context:child(childDefinition, {}):enable()
        else
          assert(not context:active(), 'failed explicit inverse remains active')
          assert(not pcall(function()
            context:effect(function()
              acquired += 1
              return function() end
            end)
          end), 'failed explicit inverse restored resource authority')
        end
      end
      local definition = plugin.define({}, {}, function(context)
        escaped = context
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
            if broken then
              error 'explicit authority inverse failure'
            end
          end
        end)
        if loading then
          disposeAndCheck(context)
        end
        return {}
      end)
      runtime:use(definition, {}):enable()
      if not loading then
        disposeAndCheck(escaped)
      end
      assert(attempts ~= nil, 'initializer cleanup assertions did not run')
      if not broken then
        expect.truthy(acquired == 1 and childCalls == 1, 'the successful cleanup restores the live owner')
      end
      runtime:close()
      expect.equal(acquired, 0, 'no explicitly cleaned resource outlives close')
    end)
  end
end

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
