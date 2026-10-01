-- A provider whose explicit disposal fails is quarantined when its attachment
-- ends. Until then it keeps serving: its consumers read it through their views,
-- including from their own inverses while they unload before it.
return function(plugin)
  local function identity(value)
    return value
  end

  local echo = plugin.capability('local/quarantine-pending-echo', 1, identity)
  local released = {}

  local provider = plugin.define(identity, {}, { echo = echo }, function(context, _config, publish)
    local doomed = context:effect(function()
      return function()
        error('the doomed inverse fails', 0)
      end
    end)
    publish:provide(echo, {
      ping = function(_self, value)
        return value
      end,
      dropDoomed = function(_self)
        doomed:dispose()
      end,
    })
  end)
  local kept
  local consumer = plugin.define(identity, { echo = echo }, {}, function(context)
    local service = context:require(echo)
    kept = service
    context:effect(function()
      return function()
        released[#released + 1] = service:ping 'released'
      end
    end)
  end)

  local runtime = plugin.runtime()
  local providerInstance = runtime:use(provider, {})
  providerInstance:enable()
  local consumerInstance = runtime:use(consumer, {})
  consumerInstance:enable()
  assert(consumerInstance:state() == 'active', consumerInstance:state())

  local ok, message = pcall(function()
    kept:dropDoomed()
  end)
  assert(not ok and tostring(message):find('the doomed inverse fails', 1, true), tostring(message))
  assert(providerInstance:state() == 'active', 'a quarantine-pending provider stays active')
  assert(kept:ping 'still served' == 'still served', 'a quarantine-pending provider keeps serving')

  providerInstance:disable()
  assert(consumerInstance:state() == 'inactive', 'the consumer unloads cleanly: ' .. consumerInstance:state())
  assert(released[1] == 'released', 'the consumer inverse reached the provider')
  assert(providerInstance:state() == 'quarantined', providerInstance:state())
  runtime:close()
end
