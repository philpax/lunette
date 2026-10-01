local plugin = require '@lunette-plugin'

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

rejects(function()
  plugin.define {
    name = 'runtime-1',
    requires = { source = table.freeze { token = serviceCapability.token, witness = identity } },
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
    rejects(function()
      publish:provide({ witness = serviceCapability.witness }, service)
    end, 'is not declared')
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
    rejects(function()
      ctx:require { witness = serviceCapability.witness }
    end, 'is not declared')
    rejects(function()
      ctx:require(setmetatable({ witness = serviceCapability.witness }, {
        __eq = function()
          return true
        end,
      }))
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

local failedRuntime = plugin.runtime()
local acquired = 0
local released = 0
local published = 0
local escapedFailure
local cancelledInstance
local instances = {}
for _, name in { 'missing', 'duplicate', 'extra', 'nil', 'returned', 'partial', 'cancelled' } do
  local capability = plugin.capability { name = 'fixture/production-failure-' .. name, schema = 1 }
  local definition = plugin.define {
    name = 'definition',
    provides = { service = capability },
    init = function(ctx, _config, publish)
      ctx:effect(function()
        acquired += 1
        return function()
          released += 1
        end
      end)
      if name == 'missing' then
        return
      elseif name == 'extra' then
        publish:provide(extraCapability, service)
      elseif name == 'nil' then
        publish:provide(capability, nil)
      elseif name == 'cancelled' then
        cancelledInstance:disable()
        publish:provide(capability, service)
      else
        publish:provide(capability, service)
        if name == 'duplicate' then
          publish:provide(capability, service)
        elseif name == 'returned' then
          return service
        elseif name == 'partial' then
          escapedFailure = publish
          error 'production partial initializer failure'
        end
      end
    end,
  }
  local dependent = failedRuntime:use(
    plugin.define {
      name = 'runtime-5',
      requires = { service = capability },
      init = function()
        published += 1
      end,
    },
    {}
  )
  local instance = failedRuntime:use(definition, {})
  if name == 'cancelled' then
    cancelledInstance = instance
  end
  table.insert(instances, instance)
  table.insert(instances, dependent)
  dependent:enable()
  instance:enable()
end
failedRuntime:drain()
assert(acquired == 7 and released == 7, tostring(acquired) .. '/' .. tostring(released))
assert(published == 0)
rejects(function()
  escapedFailure:provide(serviceCapability, service)
end, 'initializer is no longer active')
failedRuntime:close()
