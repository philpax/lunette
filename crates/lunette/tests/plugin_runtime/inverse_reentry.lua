return function(plugin)
  for _, explicit in { false, true } do
    local runtime = plugin.runtime()
    local dependency = plugin.contract('audit/inverse-dependency-' .. tostring(explicit), 1)
    local output = plugin.contract('audit/inverse-output-' .. tostring(explicit), 1)
    local events = {}
    local providerAlive = true
    local provider = plugin.define({}, { service = dependency }, function(context)
      context:effect(function()
        return function()
          table.insert(events, 'provider')
          providerAlive = false
        end
      end)
      return { service = {} }
    end)
    runtime:use(provider, {}):enable()
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
      local ok, message = pcall(function()
        effect:dispose()
      end)
      assert(not ok and string.find(tostring(message), 'reentrant inverse failure'), 'explicit failure lost its cause')
      effect:dispose()
      -- The reload requested inside the inverse unloads the activation, which
      -- runs its remaining inverse and then quarantines it.
      assert(
        table.concat(events, ',') == 'broken,remaining',
        'explicit failure cleanup order: ' .. table.concat(events, ',')
      )
    else
      assert(not pcall(function()
        context:effect(function()
          instance:reload {}
          return inverse
        end)
      end))
      assert(
        #events == 2 and events[1] == 'broken' and events[2] == 'remaining',
        'cancelled activation inverses out of order'
      )
    end
    assert(not pcall(function()
      instance:enable()
    end), 'quarantined instance accepted enable')
    assert(not pcall(function()
      instance:reload {}
    end), 'quarantined instance accepted reload')
    instance:dispose()
    runtime:drain()
    assert(loads == 1, 'failed old inverse permitted a replacement activation')
    assert(inverseCalls == 1, 'failed inverse retried')
    assert(not context:active(), 'failed allocation remains published')
    local duplicate = runtime:use(definition, {})
    assert(not pcall(function()
      duplicate:enable()
    end), 'failed cleanup released its provided reservation')
    assert(providerAlive, 'failed cleanup released its dependency')
    runtime:close()
    assert(
      table.concat(events, ',') == 'broken,remaining,provider',
      'shutdown cleanup order: ' .. table.concat(events, ',')
    )
    assert(inverseCalls == 1, 'shutdown retried a failed inverse')
  end
end
