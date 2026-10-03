-- Context:owns answers what checkOwner would decide without raising, and
-- Context:acquire checks an owner and registers the resource on its lifetime.
return function(plugin)
  local function rejects(callback, expected)
    local ok, message = pcall(callback)
    assert(not ok and tostring(message):find(expected, 1, true), tostring(message))
  end

  local resource = plugin.capability { name = 'local/ownership-resource', schema = 1 }
  local events = {}
  local provider = plugin.define {
    name = 'provider',
    provides = { resource = resource },
    init = function(context, _config, publish)
      publish:provide(resource, {
        owns = function(_self, owner)
          return context:owns(owner)
        end,
        check = function(_self, owner)
          context:checkOwner(owner)
          return true
        end,
        open = function(_self, owner, name)
          return context:acquire(owner, function()
            events[#events + 1] = 'open ' .. name
            return function()
              events[#events + 1] = 'close ' .. name
            end
          end)
        end,
      })
    end,
  }

  local stranger
  local strangerDefinition = plugin.define {
    name = 'strangerDefinition',
    init = function(context)
      stranger = context
    end,
  }
  local consumerContext
  local consumer = plugin.define {
    name = 'consumer',
    requires = { resource = resource },
    init = function(context)
      consumerContext = context
      local service = context:require(resource)
      assert(service:owns(context), 'a dependent is owned')
      assert(not service:owns(stranger), 'a context that does not depend on the provider is not owned')
      assert(service:check(context), 'a genuine owner was rejected')
      service:open(context, 'kept')
      local explicit = service:open(context, 'explicit')
      explicit:dispose()
      rejects(function()
        service:open(stranger, 'stranger')
      end, 'does not depend on this provider')
    end,
  }

  local runtime = plugin.runtime()
  local providerInstance = runtime:use(provider, {})
  providerInstance:enable()
  runtime:use(strangerDefinition, {}):enable()
  local consumerInstance = runtime:use(consumer, {})
  consumerInstance:enable()
  assert(consumerInstance:state() == 'active', tostring(consumerInstance:diagnostic()))
  assert(events[1] == 'open kept' and events[2] == 'open explicit' and events[3] == 'close explicit')

  local observed
  local observer = runtime:use(
    plugin.define {
      name = 'ownership-helpers-4',
      requires = { resource = resource },
      init = function(context)
        observed = context:require(resource)
      end,
    },
    {}
  )
  observer:enable()
  consumerInstance:disable()
  assert(events[4] == 'close kept', 'an acquired resource ends with its owner')
  assert(not observed:owns(consumerContext), 'an ended owner is not owned')
  runtime:close()
end
