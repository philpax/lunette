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
  assert(instance:state() == 'quarantined', 'failed cleanup was not quarantined')
  assert(string.find(instance:diagnostic() or '', 'cleanup failed', 1, true), 'quarantine has no diagnostic')
  assert(not pcall(function()
    instance:enable()
  end), 'quarantined instance accepted enable')
  assert(loads == 1)
end
