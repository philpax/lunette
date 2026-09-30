return function(plugin)
  local token = plugin.contract('test/nested', 1)
  local wrapper = {}
  setreadonly(wrapper, true)
  plugin.bind(token, wrapper)
  local events = {}
  local definition = plugin.define({}, { service = token }, function(context, config)
    context:effect(function()
      table.insert(events, 'outer-acquire')
      context:effect(function()
        table.insert(events, 'inner-acquire')
        return function()
          table.insert(events, 'inner-release')
        end
      end)
      error 'nested failure'
    end)
    return { service = config.service }
  end)
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, { service = wrapper })
  instance:enable()
  nested_events = events
  runtime:close()
end
