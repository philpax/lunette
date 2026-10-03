-- A definition accepts only capabilities, freezes what it declares, and lets
-- a context reach only its declared capabilities while it is current.
return function(plugin)
  local function identity(value)
    return value
  end

  local function rejects(callback, expected)
    local ok, message = pcall(callback)
    assert(not ok and tostring(message):find(expected, 1, true), tostring(message))
  end

  local serviceCapability = plugin.capability { name = 'fixture/production-service', schema = 1 }
  local extraCapability = plugin.capability { name = 'fixture/production-extra', schema = 1 }
  local service = { marker = 'original' }
  local providerContext
  local consumerContext
  local escapedPublisher
  local calls = 0

  -- A plain table, such as the capability's spec, is not a capability.
  rejects(function()
    plugin.define {
      name = 'runtime-1',
      requires = { source = { name = 'fixture/production-service', schema = 1 } },
      init = function() end,
    }
  end, 'unbound capability wrapper')

  local provisions = { source = serviceCapability }
  local provider = plugin.define {
    name = 'provider',
    provides = provisions,
    init = function(ctx, _config, publish)
      providerContext = ctx
      escapedPublisher = publish
      publish:provide(serviceCapability, service)
    end,
  }
  provisions.source = extraCapability
  assert(provider.provides.source == serviceCapability and table.isfrozen(provider.provides))
  assert(table.isfrozen(provider) and table.isfrozen(serviceCapability))
  rejects(function()
    provider.provides.source = extraCapability
  end, 'readonly')
  rejects(function()
    serviceCapability.witness = identity
  end, 'readonly')

  local declaration = { source = serviceCapability }
  local consumer = plugin.define {
    name = 'consumer',
    requires = declaration,
    init = function(ctx)
      consumerContext = ctx
      assert(ctx:require(serviceCapability).marker == 'original')
      rejects(function()
        ctx:require(extraCapability)
      end, 'is not declared')
      calls += 1
    end,
  }
  declaration.source = extraCapability
  assert(consumer.requires.source == serviceCapability and table.isfrozen(consumer.requires))
  rejects(function()
    consumer.requires.source = extraCapability
  end, 'readonly')

  local runtime = plugin.runtime()
  local providerInstance = runtime:use(provider, {})
  local consumerInstance = runtime:use(consumer, {})
  consumerInstance:enable()
  providerInstance:enable()
  runtime:drain()
  assert(calls == 1)
  providerContext:checkOwner(consumerContext)
  rejects(function()
    escapedPublisher:provide(serviceCapability, {})
  end, 'initializer is no longer active')

  local oldContext = consumerContext
  consumerInstance:reload {}
  runtime:drain()
  assert(calls == 2 and consumerContext ~= oldContext)
  rejects(function()
    oldContext:require(serviceCapability)
  end, 'stale')
  consumerInstance:disable()
  runtime:drain()
  rejects(function()
    consumerContext:require(serviceCapability)
  end, 'stale')
  runtime:close()
end
