return function(plugin)
  for _, reload in { false, true } do
    local runtime = plugin.runtime()
    local dependency = plugin.contract('audit/publication-dependency-' .. tostring(reload), 1)
    local output = plugin.contract('audit/publication-output-' .. tostring(reload), 1)
    local events = {}
    local providerAlive = true
    local providerLoads = 0
    local providerDefinition = plugin.define({}, { service = dependency }, function(context)
      providerLoads += 1
      context:effect(function()
        return function()
          table.insert(events, 'provider')
          providerAlive = false
        end
      end)
      return { service = {} }
    end)
    local provider = runtime:use(providerDefinition, {})
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
      if reload then
        provider:reload {}
      else
        provider:disable()
      end
      return { service = {} }
    end)
    local instance = runtime:use(definition, {})
    local observerLoads = 0
    local observer = plugin.define({ service = output }, {}, function()
      observerLoads += 1
      return {}
    end)
    runtime:use(observer, {}):enable()
    instance:enable()
    provider:enable()
    instance:enable()
    instance:reload {}
    instance:disable()
    instance:dispose()
    runtime:drain()
    assert(loads == 1, 'failed publication rollback permitted another load')
    assert(observerLoads == 0, 'invalid consumer was published')
    assert(not escaped:active(), 'invalid consumer context remains active')
    assert(brokenCalls == 1, 'failed inverse retried')
    assert(providerLoads == 1 and providerAlive, 'quarantine released the exact dependency generation')
    assert(not pcall(function()
      runtime:use(definition, {})
    end), 'failed publication rollback released its reservation')
    assert(table.concat(events, ',') == 'broken,remaining', 'rollback inverse order: ' .. table.concat(events, ','))
    runtime:close()
    assert(
      table.concat(events, ',') == 'broken,remaining,provider',
      'shutdown dependency order: ' .. table.concat(events, ',')
    )
    assert(brokenCalls == 1, 'shutdown retried failed rollback')
  end
end
