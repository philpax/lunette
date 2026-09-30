return function(plugin)
  local function identity(value)
    return value
  end

  local service = plugin.capability('local/cancel-service', 1, identity)
  local events = {}
  local consumer_published = false
  local escaped_provide
  local instance

  local definition = plugin.define(function(config)
    return config
  end, {}, { service = service }, function(context, config, provide)
    escaped_provide = provide
    context:effect(function()
      table.insert(events, 'acquire')
      instance:disable()
      return function()
        table.insert(events, 'release')
      end
    end)
    provide:provide(service, config.value)
  end)
  local consumer_definition = plugin.define(function(config)
    return config
  end, { service = service }, {}, function(_context, _config, _provide)
    consumer_published = true
  end)

  local runtime = plugin.runtime()
  instance = runtime:use(definition, { value = { marker = 'service' } })
  local consumer = runtime:use(consumer_definition, {})
  instance:enable()
  consumer:enable()

  assert(events[1] == 'acquire')
  assert(events[2] == 'release')
  assert(events[3] == nil)
  assert(not consumer_published)
  local ok, message = pcall(function()
    escaped_provide:provide(service, 'late')
  end)
  assert(not ok and tostring(message):find('initializer is no longer active', 1, true), tostring(message))
  runtime:close()
  assert(events[3] == nil)
end
