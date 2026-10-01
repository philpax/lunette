return function(plugin)
  local token = plugin.contract('test/yield', 1)
  local wrapper = {}
  setreadonly(wrapper, true)
  plugin.bind(token, wrapper)
  local definition = plugin.define({}, { service = token }, function(context, config)
    context:effect(function()
      coroutine.yield()
      return function() end
    end)
    return { service = config.service }
  end)
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, { service = wrapper })
  instance:enable()
  runtime:close()
end
