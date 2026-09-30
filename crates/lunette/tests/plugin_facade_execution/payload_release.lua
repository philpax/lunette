return function(plugin)
  local function identity(value)
    return value
  end

  local service = plugin.capability('local/payload-service', 1, identity)
  local escaped_provide
  local payload = payload_witness
  local definition = plugin.define(function(config)
    return config
  end, {}, { service = service }, function(_context, config, provide)
    escaped_provide = provide
    provide:provide(service, config.payload)
  end)
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, { payload = payload })
  instance:enable()
  return escaped_provide
end
