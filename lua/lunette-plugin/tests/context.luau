-- Covers subscriptions and owner-scoped resources that end with a context's activation.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'

local test = testing.suite()

type Listener = { handler: (string) -> () }
type Source = {
  listeners: { Listener },
  cancels: number,
  subscribe: ((string) -> ()) -> () -> (),
  emit: (string) -> (),
}
type ResourceService = {
  read owns: (ResourceService, adapter.Owner) -> boolean,
  read check: (ResourceService, adapter.Owner) -> boolean,
  read open: (ResourceService, adapter.Owner, string) -> adapter.Effect,
}
type FormsService = { read each: (FormsService, adapter.Owner) -> () }

-- A subscription source in the shape of a native one: subscribing answers the function that cancels it.
local function source(): Source
  local self: Source = { listeners = {}, cancels = 0 }
  function self.subscribe(handler: (string) -> ()): () -> ()
    local entry = { handler = handler }
    self.listeners[#self.listeners + 1] = entry
    return function()
      local index = table.find(self.listeners, entry)
      if index then
        table.remove(self.listeners, index)
        self.cancels += 1
      end
    end
  end
  function self.emit(event: string)
    for _, entry in ipairs(table.clone(self.listeners)) do
      entry.handler(event)
    end
  end
  return self
end

test('a subscription ends with its activation, and a handler kept past it delivers nothing', function()
  local events = source()
  local received: { string } = {}
  local runtime = adapter.runtime()
  local instance = runtime:use(
    adapter.define {
      name = 'subscriber',
      init = function(context: adapter.Context, config: { name: string })
        context:on {
          event = events.subscribe,
          run = function(event: string)
            received[#received + 1] = config.name .. ':' .. event
          end,
        }
      end,
    },
    { name = 'one' }
  )
  instance:enable()
  events.emit 'a'
  expect.equal(received[1], 'one:a', 'the first delivery')

  local kept = events.listeners[1].handler
  instance:requestReload { name = 'two' }
  expect.truthy(#events.listeners == 1 and events.cancels == 0, 'a requested reload waits for the drain')
  runtime:drain()
  expect.truthy(#events.listeners == 1 and events.cancels == 1, 'a reload replaces the subscription')
  events.emit 'b'
  expect.equal(table.concat(received, ' '), 'one:a two:b', 'the deliveries after the reload')
  kept 'late'
  expect.equal(#received, 2, 'a handler kept past its activation delivers nothing')

  instance:disable()
  expect.truthy(#events.listeners == 0 and events.cancels == 2, 'a disable cancels the subscription')
  runtime:close()
end)

test('a resource acquired for an owner ends with that owner, and only a dependent is an owner', function()
  local resource: plugin.Capability<ResourceService> =
    plugin.capability { name = 'local/ownership-resource', version = 1 }
  local events: { string } = {}
  local provider = adapter.define {
    name = 'provider',
    provides = { resource },
    init = function(context: adapter.Context, _config: {}, publish: adapter.Publisher)
      publish:provide(resource, {
        owns = function(_self: ResourceService, owner: adapter.Owner): boolean
          return context:owns(owner)
        end,
        check = function(_self: ResourceService, owner: adapter.Owner): boolean
          context:checkOwner(owner)
          return true
        end,
        open = function(_self: ResourceService, owner: adapter.Owner, name: string): adapter.Effect
          return context:acquire(owner, function(): () -> ()
            events[#events + 1] = 'open ' .. name
            return function()
              events[#events + 1] = 'close ' .. name
            end
          end)
        end,
      })
    end,
  }
  local stranger: adapter.Context?
  local consumerContext: adapter.Context?
  local consumer = adapter.define {
    name = 'consumer',
    requires = { resource },
    init = function(context: adapter.Context)
      consumerContext = context
      local service = context:require(resource)
      expect.truthy(service:owns(context), 'a dependent is owned')
      expect.falsy(service:owns(stranger), 'a context that does not depend on the provider is not owned')
      expect.truthy(service:check(context), 'a dependent passes the owner check')
      service:open(context, 'kept')
      service:open(context, 'explicit'):dispose()
      expect.raises(function()
        service:open(stranger, 'stranger')
      end, 'does not depend on this provider')
    end,
  }
  local observed: ResourceService?
  local observer = adapter.define {
    name = 'observer',
    requires = { resource },
    init = function(context: adapter.Context)
      observed = context:require(resource)
    end,
  }

  local runtime = adapter.runtime()
  runtime:use(provider, {}):enable()
  runtime
    :use(
      adapter.define {
        name = 'stranger',
        init = function(context: adapter.Context)
          stranger = context
        end,
      },
      {}
    )
    :enable()
  local consumerInstance = runtime:use(consumer, {})
  consumerInstance:enable()
  expect.equal(consumerInstance:state(), 'active', tostring(testing.diagnostic(runtime, consumerInstance)))
  expect.equal(table.concat(events, ', '), 'open kept, open explicit, close explicit', 'the resources')
  runtime:use(observer, {}):enable()
  consumerInstance:disable()
  expect.equal(events[4], 'close kept', 'an acquired resource ends with its owner')
  expect.falsy(observed:owns(consumerContext), 'an ended owner is not owned')
  runtime:close()
end)

test('every owner-scoped acquisition takes the provider or a dependent and rejects any other context', function()
  local capability: plugin.Capability<FormsService> = plugin.capability { name = 'local/ownership-forms', version = 1 }
  local acquired: { string } = {}
  local forms = {
    acquire = function(context: adapter.Context, owner: adapter.Owner): adapter.Effect
      return context:acquire(owner, function(): () -> ()
        table.insert(acquired, 'acquire')
        return function() end
      end)
    end,
    acquireDeferred = function(context: adapter.Context, owner: adapter.Owner): adapter.Effect
      return context:acquireDeferred(owner, function(): () -> ()
        table.insert(acquired, 'acquireDeferred')
        return function() end
      end)
    end,
    resource = function(context: adapter.Context, owner: adapter.Owner): adapter.Effect
      local _, effect = context:resource(owner, function(): ({}, () -> ())
        table.insert(acquired, 'resource')
        return {}, function() end
      end)
      return effect
    end,
  }
  local stranger: adapter.Context?
  local provider = adapter.define {
    name = 'provider',
    provides = { capability },
    init = function(context: adapter.Context, _config: {}, publish: adapter.Publisher)
      for _, form in forms do
        form(context, context)
      end
      publish:provide(capability, {
        each = function(_self: FormsService, owner: adapter.Owner)
          for name, form in forms do
            form(context, owner)
            expect.raises(function()
              form(context, stranger)
            end, 'does not depend on this provider', name .. ' with a stranger')
          end
        end,
      })
    end,
  }
  local consumer = adapter.define {
    name = 'consumer',
    requires = { capability },
    init = function(context: adapter.Context)
      context:require(capability):each(context)
    end,
  }
  local runtime = adapter.runtime()
  runtime
    :use(
      adapter.define {
        name = 'stranger',
        init = function(context: adapter.Context)
          stranger = context
        end,
      },
      {}
    )
    :enable()
  runtime:use(provider, {}):enable()
  local consumerInstance = runtime:use(consumer, {})
  consumerInstance:enable()
  expect.equal(consumerInstance:state(), 'active', tostring(testing.diagnostic(runtime, consumerInstance)))
  expect.equal(#acquired, 6, 'each form acquires for the provider and for its dependent')
  runtime:close()
end)

return test
