return function(plugin)
  local token = plugin.contract('test/ownership', 1)
  local wrapper = { marker = {} }
  setreadonly(wrapper, true)
  plugin.bind(token, wrapper)
  local escaped
  local definition = plugin.define({}, { service = token }, function(context, config)
    escaped = context
    context:effect(function()
      return function() end
    end)
    return { service = config.service }
  end)
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, { service = wrapper })
  instance:enable()
  runtime = nil
  collectgarbage()
  collectgarbage()
  assert(escaped:active())
end
