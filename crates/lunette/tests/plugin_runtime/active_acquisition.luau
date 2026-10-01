return function(plugin)
  for _, command in { 'close', 'disable', 'reload', 'disable-enable' } do
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
    local ok, message = pcall(function()
      contexts[1]:effect(function()
        if command == 'close' then
          runtime:close()
        elseif command == 'disable' then
          instance:disable()
        elseif command == 'disable-enable' then
          instance:disable()
          instance:enable()
        else
          instance:reload {}
        end
        runtime:drain()
        return function()
          table.insert(events, 'acquired-1')
        end
      end)
    end)
    assert(not ok and string.find(tostring(message), 'cancelled'), 'active acquisition must report cancellation')
    assert(
      #events == 2 and events[1] == 'acquired-1' and events[2] == 'base-1',
      'old inverses not released once in reverse order'
    )
    assert(not contexts[1]:active(), 'old context remains active')
    if command == 'reload' or command == 'disable-enable' then
      assert(loads == 2 and contexts[2]:active(), 'reenabling must activate a fresh context')
      assert(#events == 2, 'old cancellation drained fresh effects')
    else
      assert(loads == 1)
    end
    runtime:close()
    if command == 'reload' or command == 'disable-enable' then
      assert(#events == 3 and events[3] == 'base-2', 'fresh inverse missing at close')
    else
      assert(#events == 2, 'inverse retried at close')
    end
  end
end
