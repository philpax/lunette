return function(plugin)
  for _, command in { 'close', 'disable', 'reload' } do
    local runtime = plugin.runtime()
    local token = plugin.contract('audit/active-provider-' .. command, 1)
    local provider
    local escaped
    local events = {}
    local service = { alive = true }
    local loads = 0
    local definition = plugin.define({}, { service = token }, function(context)
      loads += 1
      local generation = loads
      local resource = { alive = true }
      service = resource
      escaped = context
      context:effect(function()
        return function()
          resource.alive = false
          table.insert(events, 'provider-' .. generation)
        end
      end)
      return { service = service }
    end)
    provider = runtime:use(definition, {})
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
    assert(not pcall(function()
      escaped:effect(function()
        if command == 'close' then
          runtime:close()
        elseif command == 'disable' then
          provider:disable()
        else
          provider:reload {}
        end
        return function()
          table.insert(events, 'acquired-1')
        end
      end)
    end))
    assert(
      table.concat(events, ',') == 'consumer-1,acquired-1,provider-1',
      'graph cleanup order: ' .. table.concat(events, ',')
    )
    runtime:close()
  end
end
