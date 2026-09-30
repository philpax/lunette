return function(plugin)
  local token = plugin.contract('test/effects', 1)
  local wrapper = { marker = {} }
  setreadonly(wrapper, true)
  plugin.bind(token, wrapper)
  local events = {}
  local definition = plugin.define({}, { service = token }, function(context, config)
    context:effect(function()
      table.insert(events, 'one')
      return function()
        table.insert(events, 'one-release')
      end
    end)
    context:effect(function()
      table.insert(events, 'two')
      return function()
        table.insert(events, 'two-release')
      end
    end)
    return { service = config.service }
  end)
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, { service = wrapper })
  instance:enable()
  instance:disable()
  instance:disable()
  runtime:close()
  assert(events[1] == 'one' and events[2] == 'two')
  assert(events[3] == 'two-release' and events[4] == 'one-release')
  assert(#events == 4)
end
