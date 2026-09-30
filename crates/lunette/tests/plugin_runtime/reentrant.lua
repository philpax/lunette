return function(plugin)
  local token = plugin.contract('test/reentrant', 1)
  local wrapper = { marker = {} }
  setreadonly(wrapper, true)
  plugin.bind(token, wrapper)
  local events = {}
  local instance
  local definition = plugin.define({}, { service = token }, function(context, config)
    table.insert(events, 'load')
    context:effect(function()
      return function()
        table.insert(events, 'release')
        instance:disable()
      end
    end)
    return { service = config.service }
  end)
  local runtime = plugin.runtime()
  instance = runtime:use(definition, { service = wrapper })
  instance:enable()
  instance:disable()
  assert(events[1] == 'load' and events[2] == 'release')
  runtime:close()
end
