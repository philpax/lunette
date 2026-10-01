return function(plugin)
  for _, child_case in { false, true } do
    local runtime = plugin.runtime()
    local token = plugin.contract('audit/pending-' .. tostring(child_case), 1)
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
      if child_case then
        context:child(consumer, {}):enable()
      end
      return { service = resource }
    end)
    runtime:use(provider, {}):enable()
    if not child_case then
      runtime:use(consumer, {}):enable()
    end
    assert(broken ~= nil, 'consumer not initialized')
    assert(not pcall(function()
      broken:dispose()
    end))
    assert(#events == 1 and events[1] == 'B')
    runtime:close()
    assert(
      #events == 3 and events[1] == 'B' and events[2] == 'A' and events[3] == 'P',
      'pending inverse must run once before provider cleanup: ' .. table.concat(events, ',')
    )
  end
end
