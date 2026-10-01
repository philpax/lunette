return function(plugin)
  local runtime = plugin.runtime()
  local token = plugin.contract('audit/reenable', 1)
  local instance
  local consumer
  local attempts = 0
  local observed = {}
  local provider = plugin.define({}, { service = token }, function(context)
    attempts += 1
    local resource = { attempt = attempts, alive = true }
    context:effect(function()
      return function()
        resource.alive = false
      end
    end)
    if attempts == 1 then
      consumer:enable()
      instance:disable()
      instance:enable()
    end
    return { service = resource }
  end)
  consumer = runtime:use(
    plugin.define({ service = token }, {}, function(context)
      local resource = context:services().service
      table.insert(observed, resource)
      return {}
    end),
    {}
  )
  instance = runtime:use(provider, {})
  instance:enable()
  assert(attempts == 2, 'cancelled load was not retried')
  assert(#observed == 1 and observed[1].attempt == 2 and observed[1].alive, 'disposed attempt published')
  runtime:close()
end
