return function(plugin)
  for _, reason in { 'initializer', 'missing', 'extra' } do
    for _, broken in { false, true } do
      local runtime = plugin.runtime()
      local suffix = reason .. '-' .. tostring(broken)
      local dependency = plugin.contract('audit/rollback-dependency-' .. suffix, 1)
      local output = plugin.contract('audit/rollback-output-' .. suffix, 1)
      local childToken = plugin.contract('audit/rollback-child-' .. suffix, 1)
      local events = {}
      local providerAlive = true
      local providerLoads = 0
      local providerContext
      local providerDefinition = plugin.define({}, { service = dependency }, function(context)
        providerLoads += 1
        providerContext = context
        context:effect(function()
          return function()
            table.insert(events, 'provider')
            providerAlive = false
          end
        end)
        return { service = 42 }
      end)
      local provider = runtime:use(providerDefinition, {})
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
        elseif reason == 'missing' then
          return {}
        else
          return { service = {}, unexpected = true }
        end
      end)
      local instance = runtime:use(definition, {})
      instance:enable()
      assert(table.concat(events, ',') == '3,2,1', 'rollback must attempt remaining inverses in reverse order')
      assert(acquired == 0, 'rollback inverse ran a new acquisition body')
      for index = 1, 3 do
        local attempt = attempts[index]
        assert(attempt ~= nil, 'rollback inverse skipped')
        assert(
          not attempt.active and not attempt.effect and not attempt.child and not attempt.owner,
          'rollback context retains resource authority'
        )
      end
      assert(childLoads == 0, 'rollback installed an activatable child')
      assert(not escaped:active() and not pcall(function()
        escaped:effect(function()
          acquired += 1
          return function() end
        end)
      end), 'completed rollback context remains usable')
      if broken then
        provider:disable()
        provider:reload {}
        provider:enable()
        instance:enable()
        instance:reload {}
        instance:dispose()
        runtime:drain()
        assert(
          loads == 1 and providerLoads == 1 and providerAlive,
          'failed rollback released its exact allocation or dependency'
        )
        assert(not pcall(function()
          runtime:use(definition, {})
        end), 'failed rollback released its reservation')
      end
      assert(
        pcall(function()
          runtime:use(childDefinition, {})
        end),
        'rollback child attempt reserved a contract'
      )
      runtime:close()
      assert(
        table.concat(events, ',') == '3,2,1,provider',
        'shutdown retried rollback or released dependencies out of order'
      )
      assert(acquired == 0 and childLoads == 0, 'rollback resource leaked after close')
    end
  end
end
