return function(plugin)
  local token = plugin.contract('test/quarantine', 1)
  local wrapper = {}
  setreadonly(wrapper, true)
  plugin.bind(token, wrapper)
  local payload = { released = false }
  local loads = 0
  local definition = plugin.define({}, { service = token }, function(context, config)
    loads += 1
    context:effect(function()
      return function()
        config.payload.released = true
        error 'cleanup failed'
      end
    end)
    return { service = config.service }
  end)
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, { service = wrapper, payload = payload })
  instance:enable()
  instance:disable()
  assert(payload.released)
  instance:enable()
  assert(loads == 1)
end
