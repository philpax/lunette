return function(plugin)
  local token = plugin.contract('test/cancel', 1)
  local wrapper = {}
  setreadonly(wrapper, true)
  plugin.bind(token, wrapper)
  local events = {}
  local escaped
  local instance
  local definition = plugin.define({}, { service = token }, function(context, config)
    escaped = context
    context:effect(function()
      table.insert(events, 'acquire')
      return function()
        table.insert(events, 'release')
      end
    end)
    instance:disable()
    return { service = config.service }
  end)
  local runtime = plugin.runtime()
  instance = runtime:use(definition, { service = wrapper })
  instance:enable()
  assert(events[1] == 'acquire' and events[2] == 'release')
  assert(not escaped:active())
  runtime:close()
end
