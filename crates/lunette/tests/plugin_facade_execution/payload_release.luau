return function(plugin)
  local service = plugin.capability { name = 'local/payload-service', schema = 1 }
  local escaped_provide
  local payload = payload_witness
  local definition = plugin.define {
    name = 'definition',
    provides = { service = service },
    init = function(_context, config, provide)
      escaped_provide = provide
      provide:provide(service, config.payload)
    end,
  }
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, { payload = payload })
  instance:enable()
  return escaped_provide
end
