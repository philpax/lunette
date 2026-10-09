-- Exercises session composition management against the native plugin runtime.

local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local composition = require '@lunette-contracts/composition'
local schema = require '@lunette-plugin/schema'
local test = testing.suite()

local function find(list, id)
  for _, current in list do
    if current.id == id then
      return current
    end
  end
  return nil
end

local function entry(service, id)
  return find(service:entries(), id)
end

local function report(needle)
  local reports = testing.takeReports()
  expect.equal(#reports, 1, table.concat(reports, '\n'))
  expect.truthy(reports[1]:find(needle, 1, true), reports[1])
end

local function configured(init)
  return plugin.consumer({
    name = 'managed-settings',
    schema = schema.object { value = schema.default(schema.number { integer = true, minimum = 0 })(1) },
    init = init,
  }).definition
end

test('start publishes a read-only service that tracks active, inactive, and failed entries', function()
  local observed, service
  local definition = configured(function(_context, settings)
    observed = settings.value
  end)
  local viewer = plugin.define {
    name = 'management-viewer',
    requires = { composition = composition.capability },
    init = function(context)
      service = context:require(composition.capability)
    end,
  }
  local broken = plugin.define {
    name = 'managed-broken',
    init = function()
      error('managed initialization fails', 0)
    end,
  }
  local running = management.start {
    { id = 'settings', definition = definition, config = { value = 4 } },
    { id = 'viewer', definition = viewer },
    { id = 'broken', definition = broken },
  }
  expect.raises(function()
    service.enable = function() end
  end, 'read%-only')
  expect.equal(observed, 4, 'the configuration')
  expect.equal(entry(service, 'composition').protected, true, 'the management entry')
  expect.equal(entry(service, 'settings').state, 'active', 'the configured entry')
  expect.truthy(entry(service, 'settings').schema ~= nil, 'a configured definition carries its schema')
  expect.equal(entry(service, 'broken').state, 'failed', 'the failing entry')
  expect.truthy(entry(service, 'broken').diagnostic:find('managed initialization fails', 1, true), 'its diagnostic')
  report 'managed initialization fails'
  service:disable 'settings'
  expect.equal(entry(service, 'settings').state, 'inactive', 'the disabled entry')
  expect.equal(entry(service, 'settings').enabled, false, 'the disabled flag')
  service:enable 'settings'
  expect.equal(entry(service, 'settings').state, 'active', 'the enabled entry')
  running.runtime:close()
end)

test('start validates every entry before activating any, and reserves the management id', function()
  local initialized = 0
  local definition = configured(function()
    initialized += 1
  end)
  expect.raises(function()
    management.start {
      { id = 'valid', definition = definition },
      { id = 'invalid', definition = definition, config = { value = 'invalid' } },
    }
  end, 'managed%-settings')
  expect.raises(function()
    management.start { { id = 'composition', definition = definition } }
  end, 'reserved')
  expect.equal(initialized, 0, 'no entry activated')
  expect.equal(#testing.takeReports(), 0, 'nothing is reported')
end)

test('an invalid configuration is rejected without disturbing the live activation', function()
  local loads, releases = 0, 0
  local definition = configured(function(context)
    loads += 1
    context:effect(function()
      return function()
        releases += 1
      end
    end)
  end)
  local running = management.start { { id = 'settings', definition = definition } }
  for _, invalid in { { value = -1 }, { unknown = true } } do
    expect.raises(function()
      running.service:configure('settings', invalid)
    end, 'managed%-settings')
  end
  expect.equal(entry(running.service, 'settings').state, 'active', 'the entry')
  expect.equal(loads, 1, 'the loads')
  expect.equal(releases, 0, 'the releases')
  running.runtime:close()
end)

test('a failed change keeps the last working configuration for recovery', function()
  local observed, failRecovery = nil, false
  local definition = configured(function(_context, settings)
    if settings.value == 9 or (failRecovery and settings.value == 2) then
      error('managed build fails', 0)
    end
    observed = settings.value
  end)
  local running = management.start { { id = 'settings', definition = definition, config = { value = 1 } } }
  local service = running.service
  service:configure('settings', { value = 2 })
  expect.equal(observed, 2, 'the accepted configuration')
  expect.equal(entry(service, 'settings').previousConfig.value, 1, 'the history after a success')
  service:configure('settings', { value = 9 })
  report 'managed build fails'
  expect.equal(entry(service, 'settings').state, 'failed', 'the failed change')
  expect.equal(entry(service, 'settings').previousConfig.value, 2, 'the last working configuration')
  failRecovery = true
  service:recover 'settings'
  report 'managed build fails'
  expect.equal(entry(service, 'settings').previousConfig.value, 2, 'a failed recovery keeps the history')
  failRecovery = false
  service:recover 'settings'
  expect.equal(entry(service, 'settings').state, 'active', 'the recovered entry')
  expect.equal(observed, 2, 'the recovered configuration')
  expect.raises(function()
    service:recover 'settings'
  end, 'no previous configuration')
  running.runtime:close()
end)

test(
  'a removed entry restores from the catalog with its latest configuration, and a failed cleanup quarantines',
  function()
    local factories, received = 0, nil
    local definition = configured(function(_context, settings)
      received = settings.value
    end)
    local broken = plugin.define {
      name = 'managed-cleanup',
      init = function(context)
        context:effect(function()
          return function()
            error('managed cleanup fails', 0)
          end
        end)
      end,
    }
    local running = management.start {
      {
        id = 'settings',
        factory = function()
          factories += 1
          return definition
        end,
      },
      { id = 'broken', definition = broken },
    }
    local service = running.service
    local started = factories
    service:configure('settings', { value = 7 })
    local originalId = entry(service, 'settings').instanceId
    service:remove 'settings'
    expect.equal(entry(service, 'settings'), nil, 'the removed entry')
    expect.equal(find(service:catalog(), 'settings').installed, false, 'the catalog entry')
    expect.raises(function()
      service:enable 'settings'
    end, 'unknown entry')
    service:restore 'settings'
    local restored = entry(service, 'settings')
    expect.equal(restored.state, 'active', 'the restored entry')
    expect.truthy(restored.instanceId ~= originalId, 'the restored entry is a new instance')
    expect.equal(received, 7, 'the restored configuration')
    expect.equal(factories, started, 'restoration never runs the factory again')
    expect.raises(function()
      service:restore 'settings'
    end, 'already exists')
    expect.raises(function()
      service:remove 'broken'
    end, 'quarantined')
    report 'managed cleanup fails'
    expect.equal(entry(service, 'broken').state, 'quarantined', 'the entry whose cleanup failed')
    running.runtime:close()
  end
)

test('protection covers the providers a protected entry depends on and the owners of their children', function()
  local capability = plugin.capability { name = 'local/management-protected', schema = 1 }
  local rootCapability = plugin.capability { name = 'local/management-root', schema = 1 }
  local root = plugin.provider({
    name = 'managed-root',
    capability = rootCapability,
    build = function()
      return {}
    end,
  }).definition
  local child = plugin.define {
    name = 'managed-child',
    requires = { root = rootCapability },
    provides = { output = capability },
    init = function(context, _config, publish)
      context:require(rootCapability)
      publish:provide(capability, {})
    end,
  }
  local owner
  local parent = plugin.define {
    name = 'managed-parent',
    init = function(context)
      owner = context
      context:child(child, {}):enable()
    end,
  }
  local viewer = plugin.define {
    name = 'managed-protected-viewer',
    requires = { service = capability },
    init = function(context)
      context:require(capability)
    end,
  }
  local running = management.start({
    { id = 'root', definition = root },
    { id = 'parent', definition = parent },
    { id = 'manager', definition = viewer },
  }, { protected = { 'manager' } })
  local service = running.service
  expect.equal(service:ownerId(owner), entry(service, 'parent').instanceId, 'the owner of a context')
  expect.equal(service:ownerId {}, nil, 'a forged context')
  for _, id in { 'root', 'parent', 'manager' } do
    expect.equal(entry(service, id).protected, true, id .. ' is protected')
    for _, action in { 'disable', 'remove' } do
      expect.raises(function()
        service[action](service, id)
      end, 'cannot be changed')
    end
  end
  running.runtime:close()
end)

test('a provider outage keeps the factory definition and composed configuration of a dependent', function()
  local capability = plugin.capability { name = 'local/managed-composed-provider', schema = 1 }
  local provider = plugin.define {
    name = 'managed-composed-provider',
    provides = { service = capability },
    init = function(_context, _config, publisher)
      publisher:provide(capability, {})
    end,
  }
  local made, received = 0, nil
  local consumer = plugin.consumer {
    name = 'managed-composed-dependent',
    requires = { service = capability },
    schema = schema.object { label = schema.default(schema.string()) 'default' },
    init = function(context, settings)
      context:require(capability)
      received = settings.label
    end,
  }
  local running = management.start(plugin.compose({
    { id = 'provider', definition = provider },
    {
      id = 'dependent',
      factory = function()
        made += 1
        return consumer.definition
      end,
    },
  }, { { id = 'dependent', config = { label = 'composed' } } }))
  local started = made
  running.service:disable 'provider'
  expect.equal(entry(running.service, 'dependent').state, 'inactive', 'the dependent during the outage')
  running.service:enable 'provider'
  expect.equal(entry(running.service, 'dependent').state, 'active', 'the dependent after the outage')
  expect.equal(received, 'composed', 'the composed configuration')
  expect.equal(made, started, 'recovery runs no factory')
  running.runtime:close()
end)

test('requestReload defers the reload to the next drain', function()
  local observed
  local runtime = plugin.runtime()
  local instance = runtime:use(
    plugin.define {
      name = 'managed-deferred-reload',
      init = function(_context, config)
        observed = config.value
      end,
    },
    { value = 1 }
  )
  instance:enable()
  instance:requestReload { value = 2 }
  expect.equal(observed, 1, 'before the drain')
  runtime:drain()
  expect.equal(observed, 2, 'after the drain')
  runtime:close()
end)

return test
