return function(plugin)
  local definition = plugin.define({}, {}, function(context, config)
    context:effect(function()
      return function()
        config.released = true
      end
    end)
    return {}
  end)
  local runtime = plugin.runtime()
  local payload = { released = false }
  local instance = runtime:use(definition, payload)
  instance:enable()
  witness_payload = payload
  witness_instance = instance
  witness_runtime = runtime
end
