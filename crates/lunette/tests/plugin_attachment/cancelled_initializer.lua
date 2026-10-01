-- An initializer that raises because its own activation was cancelled ends
-- the load as cancelled, not failed, and reports nothing.
return function(plugin)
  local runtime = plugin.runtime()
  local instance
  local definition = plugin.define({}, {}, function(context)
    instance:disable()
    context:effect(function()
      return function() end
    end)
    return {}
  end, 'cancelled initializer')
  instance = runtime:use(definition, {})
  instance:enable()
  assert(instance:state() == 'inactive', 'a cancelled load ended as ' .. instance:state())
  assert(instance:diagnostic() == nil, 'a cancelled load left a diagnostic: ' .. tostring(instance:diagnostic()))
  runtime:close()
end
