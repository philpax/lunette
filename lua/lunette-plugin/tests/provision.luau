-- Covers provision staging, rollback of a failed load, and unwinding in reverse order.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'

local test = testing.suite()

type Clock = { read kind: 'clock' }
type Marker = { read marker: string }

local function recorded(context: adapter.Context, events: { string }, name: string)
  context:effect(function(): () -> ()
    events[#events + 1] = name .. ' acquire'
    return function()
      events[#events + 1] = name .. ' release'
    end
  end)
end

test('a provider, its child, and its consumers load in order and unload in reverse', function()
  local clock: plugin.Capability<Clock> = plugin.capability { name = 'local/order-clock', version = 1 }
  local childCapability: plugin.Capability<Clock> = plugin.capability { name = 'local/order-child', version = 1 }
  local events: { string } = {}
  local providerContext: adapter.Context?
  local childConfig: Clock?
  local child = adapter.define {
    name = 'child',
    provides = { childCapability },
    init = function(context: adapter.Context, config: { value: Clock }, publish: adapter.Publisher)
      childConfig = config.value
      recorded(context, events, 'child')
      publish:provide(childCapability, config.value)
    end,
  }
  local provider = adapter.define {
    name = 'provider',
    provides = { clock },
    init = function(context: adapter.Context, config: { clock: Clock }, publish: adapter.Publisher)
      providerContext = context
      context:child(child, { value = config.clock })
      recorded(context, events, 'provider')
      publish:provide(clock, config.clock)
    end,
  }
  local consumer = adapter.define {
    name = 'consumer',
    requires = { clock },
    init = function(context: adapter.Context, config: { name: string })
      expect.equal(context:require(clock).kind, 'clock', 'the service ' .. config.name .. ' reads')
      providerContext:checkOwner(context)
      recorded(context, events, config.name)
    end,
  }

  local runtime = adapter.runtime()
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
  local service: plugin.Capability<string> = plugin.capability { name = 'local/reloaded', version = 1 }
  local events: { string } = {}
  local provider = adapter.define {
    name = 'reloaded',
    provides = { service },
    init = function(context: adapter.Context, config: { value: string }, publish: adapter.Publisher)
      recorded(context, events, 'provider ' .. config.value)
      publish:provide(service, config.value)
    end,
  }
  local consumer = adapter.define {
    name = 'dependent',
    requires = { service },
    init = function(context: adapter.Context)
      recorded(context, events, 'consumer ' .. context:require(service))
    end,
  }
  local runtime = adapter.runtime()
  local instance = runtime:use(provider, { value = 'one' })
  instance:enable()
  runtime:use(consumer, {}):enable()
  instance:requestReload { value = 'two' }
  runtime:drain()
  expect.equal(
    table.concat(events, ', '),
    'provider one acquire, consumer one acquire, consumer one release, provider one release, '
      .. 'provider two acquire, consumer two acquire',
    'the order'
  )
  runtime:close()
end)

test('consumers load only once every provision is staged, behind a view of the value', function()
  local first: plugin.Capability<Marker> = plugin.capability { name = 'local/staged-first', version = 1 }
  local second: plugin.Capability<Marker> = plugin.capability { name = 'local/staged-second', version = 1 }
  local firstValue = { marker = 'first' }
  local loaded: { string } = {}
  local provider = adapter.define {
    name = 'provider',
    provides = { first, second },
    init = function(_context: adapter.Context, _config: {}, publish: adapter.Publisher)
      publish:provide(first, firstValue)
      expect.equal(#loaded, 0, 'consumers after the first provision')
      publish:provide(second, { marker = 'second' })
      expect.equal(#loaded, 0, 'consumers after the second provision')
    end,
  }
  local consumer = adapter.define {
    name = 'consumer',
    requires = { second, first },
    init = function(context: adapter.Context, config: { name: string })
      local view = context:require(first)
      expect.truthy(view.marker == 'first' and not rawequal(view, firstValue), 'the first service is a view')
      expect.equal(context:require(second).marker, 'second', 'the second service')
      loaded[#loaded + 1] = config.name
    end,
  }
  local runtime = adapter.runtime()
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
      message = "provided record is missing field 'local/failing-missing@1'",
      provide = function() end,
    },
    {
      name = 'raised',
      message = 'initializer failure after a provision',
      provide = function(publish: adapter.Publisher, capability: plugin.Capability<string>): never
        publish:provide(capability, 'staged')
        error 'initializer failure after a provision'
      end,
    },
  }
  for _, case in cases do
    local capability: plugin.Capability<string> =
      plugin.capability { name = 'local/failing-' .. case.name, version = 1 }
    local events: { string } = {}
    local escaped: adapter.Publisher?
    local consumed = false
    local runtime = adapter.runtime()
    runtime
      :use(
        adapter.define {
          name = 'consumer',
          requires = { capability },
          init = function()
            consumed = true
          end,
        },
        {}
      )
      :enable()
    local provider = runtime:use(
      adapter.define {
        name = 'failing',
        provides = { capability },
        init = function(context: adapter.Context, _config: {}, publish: adapter.Publisher)
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
