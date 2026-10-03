-- Covers what a context registers on its activation's lifetime: subscriptions through `on`, and resources a
-- provider acquires for an owner through `acquire`, which `owns` and `checkOwner` decide.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'

local test = testing.suite()

-- A subscription source in the shape of a native one: subscribing answers the function that cancels it.
local function source()
  local self = { listeners = {}, cancels = 0 }
  function self.subscribe(handler)
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
  function self.emit(event)
    for _, entry in ipairs(table.clone(self.listeners)) do
      entry.handler(event)
    end
  end
  return self
end

test('a subscription ends with its activation, and a handler kept past it delivers nothing', function()
  local events = source()
  local received = {}
  local runtime = plugin.runtime()
  local instance = runtime:use(
    plugin.define {
      name = 'subscriber',
      init = function(context, config)
        context:on {
          event = events.subscribe,
          run = function(event)
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
  instance:reload { name = 'two' }
  expect.truthy(#events.listeners == 1 and events.cancels == 1, 'a reload replaces the subscription')
  events.emit 'b'
  expect.equal(table.concat(received, ' '), 'one:a two:b', 'the deliveries after the reload')
  kept 'late'
  expect.equal(#received, 2, 'a handler kept past its activation delivers nothing')

  instance:disable()
  expect.truthy(#events.listeners == 0 and events.cancels == 2, 'a disable cancels the subscription')
  runtime:close()
end)

test('a subscription source that answers no cancel function fails the load', function()
  local runtime = plugin.runtime()
  local failing = runtime:use(
    plugin.define {
      name = 'failing',
      init = function(context)
        context:on {
          event = function()
            return 'not a cancel function'
          end,
          run = function() end,
        }
      end,
    },
    {}
  )
  failing:enable()
  expect.equal(failing:state(), 'failed', 'the instance')
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the reports')
  expect.truthy(reports[1]:find('answers the function that cancels it', 1, true), reports[1])
  runtime:close()
end)

test('a malformed subscription raises at the call', function()
  local events = source()
  local runtime = plugin.runtime()
  local checked = runtime:use(
    plugin.define {
      name = 'checked',
      init = function(context)
        expect.raises(function()
          context:on { event = events.subscribe, handler = function() end }
        end, 'plugin on: unknown field handler; the fields are event and run')
      end,
    },
    {}
  )
  checked:enable()
  expect.equal(checked:state(), 'active', 'the instance')
  runtime:close()
end)

test('a resource acquired for an owner ends with that owner, and only a dependent is an owner', function()
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
  local consumerContext
  local consumer = plugin.define {
    name = 'consumer',
    requires = { resource = resource },
    init = function(context)
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
  local observed
  local observer = plugin.define {
    name = 'observer',
    requires = { resource = resource },
    init = function(context)
      observed = context:require(resource)
    end,
  }

  local runtime = plugin.runtime()
  runtime:use(provider, {}):enable()
  runtime
    :use(
      plugin.define {
        name = 'stranger',
        init = function(context)
          stranger = context
        end,
      },
      {}
    )
    :enable()
  local consumerInstance = runtime:use(consumer, {})
  consumerInstance:enable()
  expect.equal(consumerInstance:state(), 'active', tostring(consumerInstance:diagnostic()))
  expect.equal(table.concat(events, ', '), 'open kept, open explicit, close explicit', 'the resources')
  runtime:use(observer, {}):enable()
  consumerInstance:disable()
  expect.equal(events[4], 'close kept', 'an acquired resource ends with its owner')
  expect.falsy(observed:owns(consumerContext), 'an ended owner is not owned')
  runtime:close()
end)

return test
