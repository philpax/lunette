-- Covers provision staging, rollback of a failed load, and unwinding in reverse order.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'

local test = testing.suite()

local function recorded(context, events, name)
  context:effect(function()
    events[#events + 1] = name .. ' acquire'
    return function()
      events[#events + 1] = name .. ' release'
    end
  end)
end

test('a provider, its child, and its consumers load in order and unload in reverse', function()
  local clock = plugin.capability { name = 'local/order-clock', schema = 1 }
  local childCapability = plugin.capability { name = 'local/order-child', schema = 1 }
  local events = {}
  local providerContext
  local childConfig
  local child = plugin.define {
    name = 'child',
    provides = { child = childCapability },
    init = function(context, config, publish)
      childConfig = config.value
      recorded(context, events, 'child')
      publish:provide(childCapability, config.value)
    end,
  }
  local provider = plugin.define {
    name = 'provider',
    provides = { clock = clock },
    init = function(context, config, publish)
      providerContext = context
      context:child(child, { value = config.clock }):enable()
      recorded(context, events, 'provider')
      publish:provide(clock, config.clock)
    end,
  }
  local consumer = plugin.define {
    name = 'consumer',
    requires = { clock = clock },
    init = function(context, config)
      expect.equal(context:require(clock).kind, 'clock', 'the service ' .. config.name .. ' reads')
      providerContext:checkOwner(context)
      recorded(context, events, config.name)
    end,
  }

  local runtime = plugin.runtime()
  local clockValue = { kind = 'clock' }
  local instances = {
    runtime:use(provider, { clock = clockValue }),
    runtime:use(consumer, { name = 'first' }),
    runtime:use(consumer, { name = 'second' }),
  }
  for _, instance in instances do
    instance:enable()
  end
  runtime:close()
  expect.truthy(rawequal(childConfig, clockValue), 'a configuration reaches the child unchanged')
  expect.equal(
    table.concat(events, ', '),
    'provider acquire, child acquire, first acquire, second acquire, '
      .. 'first release, second release, child release, provider release',
    'the order'
  )
end)

test('a provider reload releases the old activation and its dependents, then loads them again', function()
  local service = plugin.capability { name = 'local/reloaded', schema = 1 }
  local events = {}
  local provider = plugin.define {
    name = 'reloaded',
    provides = { service = service },
    init = function(context, config, publish)
      recorded(context, events, 'provider ' .. config.value)
      publish:provide(service, config.value)
    end,
  }
  local consumer = plugin.define {
    name = 'dependent',
    requires = { service = service },
    init = function(context)
      recorded(context, events, 'consumer ' .. context:require(service))
    end,
  }
  local runtime = plugin.runtime()
  local instance = runtime:use(provider, { value = 'one' })
  instance:enable()
  runtime:use(consumer, {}):enable()
  instance:reload { value = 'two' }
  expect.equal(
    table.concat(events, ', '),
    'provider one acquire, consumer one acquire, consumer one release, provider one release, '
      .. 'provider two acquire, consumer two acquire',
    'the order'
  )
  runtime:close()
end)

test('consumers load only once every provision is staged, behind a view of the value', function()
  local first = plugin.capability { name = 'local/staged-first', schema = 1 }
  local second = plugin.capability { name = 'local/staged-second', schema = 1 }
  local firstValue = { marker = 'first' }
  local loaded = {}
  local provider = plugin.define {
    name = 'provider',
    provides = { first = first, second = second },
    init = function(_context, _config, publish)
      publish:provide(first, firstValue)
      expect.equal(#loaded, 0, 'consumers after the first provision')
      publish:provide(second, { marker = 'second' })
      expect.equal(#loaded, 0, 'consumers after the second provision')
    end,
  }
  local consumer = plugin.define {
    name = 'consumer',
    requires = { second = second, first = first },
    init = function(context, config)
      local view = context:require(first)
      expect.truthy(view.marker == 'first' and not rawequal(view, firstValue), 'the first service is a view')
      expect.equal(context:require(second).marker, 'second', 'the second service')
      loaded[#loaded + 1] = config.name
    end,
  }
  local runtime = plugin.runtime()
  runtime:use(consumer, { name = 'one' }):enable()
  runtime:use(consumer, { name = 'two' }):enable()
  expect.equal(#loaded, 0, 'consumers before the provider')
  runtime:use(provider, {}):enable()
  expect.equal(table.concat(loaded, ' '), 'one two', 'the consumers loaded')
  runtime:close()
end)

test('a failed provision rolls back every effect in reverse and publishes nothing', function()
  local cases = {
    {
      name = 'missing',
      message = "provided record is missing field 'service'",
      provide = function() end,
    },
    {
      name = 'raised',
      message = 'initializer failure after a provision',
      provide = function(publish, capability)
        publish:provide(capability, 'staged')
        error 'initializer failure after a provision'
      end,
    },
  }
  for _, case in cases do
    local capability = plugin.capability { name = 'local/failing-' .. case.name, schema = 1 }
    local events = {}
    local escaped
    local consumed = false
    local runtime = plugin.runtime()
    runtime
      :use(
        plugin.define {
          name = 'consumer',
          requires = { service = capability },
          init = function()
            consumed = true
          end,
        },
        {}
      )
      :enable()
    local provider = runtime:use(
      plugin.define {
        name = 'failing',
        provides = { service = capability },
        init = function(context, _config, publish)
          escaped = publish
          recorded(context, events, 'outer')
          recorded(context, events, 'inner')
          case.provide(publish, capability)
        end,
      },
      {}
    )
    provider:enable()
    local reports = testing.takeReports()
    expect.equal(#reports, 1, case.name .. ': the reports')
    expect.truthy(reports[1]:find(case.message, 1, true), case.name .. ': the report ' .. tostring(reports[1]))
    expect.equal(provider:state(), 'failed', case.name .. ': the provider')
    expect.falsy(consumed, case.name .. ': the consumer was published')
    expect.equal(
      table.concat(events, ', '),
      'outer acquire, inner acquire, inner release, outer release',
      case.name .. ': the rollback'
    )
    expect.raises(function()
      escaped:provide(capability, 'late')
    end, 'initializer is no longer active', case.name .. ': a late provision')
    runtime:close()
  end
end)

return test
