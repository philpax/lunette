return function(plugin)
  local token = plugin.contract('test/stale', 1)
  local wrapper = {}
  setreadonly(wrapper, true)
  plugin.bind(token, wrapper)
  local old_context
  local definition = plugin.define({}, { service = token }, function(context, config)
    old_context = context
    return { service = config.service }
  end)
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, { service = wrapper })
  instance:enable()
  instance:disable()
  assert(not pcall(function()
    old_context:effect(function()
      return function() end
    end)
  end))
  runtime:close()
end
