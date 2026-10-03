-- Covers the native runtime rolling back a failed load: inverses run in reverse order with resource authority
-- revoked and dependency reads kept, a failing inverse quarantines the instance, and an acquisition that nests,
-- yields, or publishes a record the definition does not declare is rolled back.
local testing = require '@testing'
local expect = testing.expect
local plugin = require('@lunette').plugin

local test = testing.suite()

-- Asserts that `reports` holds exactly the messages containing each of `wanted`, in any order.
local function expectReports(reports, wanted, context)
  expect.equal(#reports, #wanted, context .. ': ' .. table.concat(reports, '\n'))
  for _, needle in wanted do
    local found = false
    for _, report in reports do
      found = found or string.find(report, needle, 1, true) ~= nil
    end
    expect.truthy(found, context .. ': no report contains ' .. needle .. ': ' .. table.concat(reports, '\n'))
  end
end

local ROLLBACK_FAILURES = {
  initializer = 'rollback authority initializer failure',
  missing = "provided record is missing field 'service'",
  extra = "provided record has unexpected field 'unexpected'",
}

for _, reason in { 'initializer', 'missing', 'extra' } do
  for _, broken in { false, true } do
    local title = 'a load failing by '
      .. reason
      .. ' rolls back with resource authority revoked before its inverses'
      .. if broken then ', and a failing inverse quarantines it' else ''
    test(title, function()
      local runtime = plugin.runtime()
      local suffix = reason .. '-' .. tostring(broken)
      local dependency = plugin.contract('audit/rollback-dependency-' .. suffix, 1)
      local output = plugin.contract('audit/rollback-output-' .. suffix, 1)
      local childToken = plugin.contract('audit/rollback-child-' .. suffix, 1)
      local events = {}
      local providerAlive = true
      local providerLoads = 0
      local providerContext
      local provider = runtime:use(
        plugin.define({}, { service = dependency }, function(context)
          providerLoads += 1
          providerContext = context
          context:effect(function()
            return function()
              table.insert(events, 'provider')
              providerAlive = false
            end
          end)
          return { service = 42 }
        end),
        {}
      )
      provider:enable()
      local childLoads = 0
      local childDefinition = plugin.define({}, { service = childToken }, function()
        childLoads += 1
        return { service = {} }
      end)
      local acquired = 0
      local loads = 0
      local escaped
      local attempts = {}
      local definition = plugin.define({ dependency = dependency }, { service = output }, function(context)
        loads += 1
        escaped = context
        for ordinal = 1, 3 do
          local index = ordinal
          context:effect(function()
            return function()
              table.insert(events, tostring(index))
              assert(providerAlive and context:services().dependency == 42, 'rollback lost dependency read authority')
              attempts[index] = {
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
                owner = pcall(function()
                  providerContext:checkOwner(context)
                end),
              }
              if broken and index == 2 then
                error 'rollback authority inverse failure'
              end
            end
          end)
        end
        if reason == 'initializer' then
          error 'rollback authority initializer failure'
        elseif reason == 'extra' then
          return { service = {}, unexpected = true }
        end
        return {}
      end)
      local instance = runtime:use(definition, {})
      instance:enable()
      expect.equal(table.concat(events, ','), '3,2,1', 'the remaining inverses run in reverse order')
      expect.equal(acquired, 0, 'no rollback inverse ran a new acquisition body')
      for index = 1, 3 do
        local attempt = attempts[index]
        assert(attempt ~= nil, 'rollback inverse ' .. index .. ' skipped')
        assert(
          not attempt.active and not attempt.effect and not attempt.child and not attempt.owner,
          'rollback context retains resource authority'
        )
      end
      expect.equal(childLoads, 0, 'no rollback installed an activatable child')
      expect.falsy(escaped:active(), 'the completed rollback context is active')
      expect.raises(function()
        escaped:effect(function()
          acquired += 1
          return function() end
        end)
      end, nil, 'an effect on the completed rollback context')
      local wanted = { ROLLBACK_FAILURES[reason] }
      if broken then
        table.insert(wanted, 'rollback authority inverse failure')
        expect.equal(instance:state(), 'quarantined', 'the failed rollback')
        provider:disable()
        provider:reload {}
        provider:enable()
        expect.raises(function()
          instance:enable()
        end, nil, 'enabling the quarantined instance')
        expect.raises(function()
          instance:reload {}
        end, nil, 'reloading the quarantined instance')
        instance:dispose()
        runtime:drain()
        expect.equal(loads, 1, 'the failed rollback is not retried')
        expect.equal(providerLoads, 2, 'the quarantine does not pin its dependency')
        local duplicate = runtime:use(definition, {})
        expect.raises(function()
          duplicate:enable()
        end, nil, 'the failed rollback keeps its reservation')
      end
      expectReports(testing.takeReports(), wanted, 'the reported failures')
      -- The rollback's child attempts reserved no contract, so the child can still be installed.
      runtime:use(childDefinition, {})
      runtime:close()
      expect.equal(
        table.concat(events, ','),
        if broken then '3,2,1,provider,provider' else '3,2,1,provider',
        'shutdown neither retries the rollback nor releases dependencies out of order'
      )
      expect.equal(acquired + childLoads, 0, 'no rollback resource outlives close')
    end)
  end
end

for _, request in { 'disable', 'reload' } do
  test(
    'a dependency ' .. request .. ' during load rolls back, quarantines a failing inverse, and pins nothing',
    function()
      local runtime = plugin.runtime()
      local dependency = plugin.contract('audit/publication-dependency-' .. request, 1)
      local output = plugin.contract('audit/publication-output-' .. request, 1)
      local events = {}
      local providerAlive = true
      local providerLoads = 0
      local provider = runtime:use(
        plugin.define({}, { service = dependency }, function(context)
          providerLoads += 1
          providerAlive = true
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
      provider:enable()
      local loads = 0
      local brokenCalls = 0
      local escaped
      local definition = plugin.define({ dependency = dependency }, { service = output }, function(context)
        loads += 1
        escaped = context
        context:effect(function()
          return function()
            assert(providerAlive and context:services().dependency ~= nil, 'dependency unavailable during rollback')
            assert(not context:active(), 'invalid publication rollback context remains active')
            local acquired = 0
            assert(not pcall(function()
              context:effect(function()
                acquired += 1
                return function() end
              end)
            end), 'invalid publication rollback accepts effect')
            assert(acquired == 0, 'invalid publication rollback invoked acquisition')
            assert(not pcall(function()
              context:child(
                plugin.define({}, {}, function()
                  return {}
                end),
                {}
              )
            end), 'invalid publication rollback accepts child')
            table.insert(events, 'remaining')
          end
        end)
        context:effect(function()
          return function()
            brokenCalls += 1
            table.insert(events, 'broken')
            error 'dependency publication rollback failure'
          end
        end)
        if request == 'reload' then
          provider:reload {}
        else
          provider:disable()
        end
        return { service = {} }
      end)
      local instance = runtime:use(definition, {})
      local observerLoads = 0
      runtime
        :use(
          plugin.define({ service = output }, {}, function()
            observerLoads += 1
            return {}
          end),
          {}
        )
        :enable()
      instance:enable()
      expect.equal(instance:state(), 'quarantined', 'the failed publication rollback')
      -- The quarantined consumer holds no allocation, so it does not pin the provider: the requested disable or
      -- reload is carried out.
      expect.equal(table.concat(events, ','), 'broken,remaining,provider', 'the rollback inverse order')
      provider:enable()
      expect.raises(function()
        instance:enable()
      end, nil, 'enabling the quarantined instance')
      expect.raises(function()
        instance:reload {}
      end, nil, 'reloading the quarantined instance')
      instance:disable()
      instance:dispose()
      runtime:drain()
      expect.equal(loads, 1, 'the failed publication rollback permits no other load')
      expect.equal(observerLoads, 0, 'the invalid consumer is not published')
      expect.falsy(escaped:active(), 'the invalid consumer context is active')
      expect.equal(brokenCalls, 1, 'the failed inverse is not retried')
      expect.truthy(providerLoads == 2 and providerAlive, 'the provider is replaced')
      local duplicate = runtime:use(definition, {})
      expect.raises(function()
        duplicate:enable()
      end, nil, 'the failed publication rollback keeps its reservation')
      local reports = testing.takeReports()
      expect.equal(#reports, 2, table.concat(reports, '\n'))
      local rollback, wiring = 0, 0
      for _, report in reports do
        if string.find(report, 'dependency publication rollback failure', 1, true) then
          rollback += 1
        elseif
          string.sub(report, 1, #'plugin wiring: ') == 'plugin wiring: '
          and string.find(report, 'is quarantined after a cleanup failure', 1, true)
        then
          wiring += 1
        end
      end
      expect.equal(rollback, 1, 'the rollback failure is reported')
      expect.equal(wiring, 1, 'the observer names the quarantined provider')
      runtime:close()
      expect.equal(table.concat(events, ','), 'broken,remaining,provider,provider', 'the shutdown dependency order')
      expect.equal(brokenCalls, 1, 'shutdown does not retry the failed rollback')
    end
  )
end

test('an effect acquired inside a failing acquisition is released with the failed load', function()
  local token = plugin.contract('test/nested', 1)
  local events = {}
  local definition = plugin.define({}, { service = token }, function(context)
    context:effect(function()
      table.insert(events, 'outer-acquire')
      context:effect(function()
        table.insert(events, 'inner-acquire')
        return function()
          table.insert(events, 'inner-release')
        end
      end)
      error 'nested failure'
    end)
    return { service = {} }
  end)
  local runtime = plugin.runtime()
  runtime:use(definition, {}):enable()
  expect.equal(table.concat(events, ','), 'outer-acquire,inner-acquire,inner-release', 'the nested acquisition')
  local reports = testing.takeReports()
  expect.equal(#reports, 1, table.concat(reports, '\n'))
  expect.truthy(string.find(reports[1], 'nested failure', 1, true), reports[1])
  runtime:close()
end)

test('an acquisition that yields fails the load', function()
  local token = plugin.contract('test/yield', 1)
  local definition = plugin.define({}, { service = token }, function(context)
    context:effect(function()
      coroutine.yield()
      return function() end
    end)
    return { service = {} }
  end)
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, {})
  instance:enable()
  expect.equal(instance:state(), 'failed', 'the yielding load')
  local reports = testing.takeReports()
  expect.equal(#reports, 1, table.concat(reports, '\n'))
  expect.truthy(string.find(reports[1], 'yield', 1, true), reports[1])
  runtime:close()
end)

return test
