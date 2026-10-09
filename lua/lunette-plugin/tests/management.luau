-- Exercises session composition management against the native plugin runtime.

local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local composition = require '@lunette-contracts/composition'
local schema = require '@lunette-plugin/schema'
local test = testing.suite()

local fixture = require './support/management_fixture'
local entry = fixture.entry
local configured, report = fixture.configured, fixture.report

test('start publishes a protected service and tracks enabled disabled and failed entries', function()
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
  for name, method in running.service do
    expect.equal(service[name], method, 'the published view forwards method ' .. name)
  end
  expect.raises(function()
    service.enable = function() end
  end, 'read%-only')
  expect.equal(observed, 4)
  expect.equal(entry(service, 'composition').protected, true)
  expect.equal(entry(service, 'settings').state, 'active')
  expect.truthy(entry(service, 'settings').schema ~= nil, 'a configured definition carries its schema')
  expect.equal(entry(service, 'viewer').schema, nil, 'a raw definition has none')
  expect.equal(entry(service, 'broken').state, 'failed')
  expect.truthy(entry(service, 'broken').diagnostic:find('managed initialization fails', 1, true))
  report 'managed initialization fails'
  service:disable 'settings'
  expect.equal(entry(service, 'settings').state, 'inactive')
  expect.equal(entry(service, 'settings').enabled, false)
  service:enable 'settings'
  expect.equal(entry(service, 'settings').state, 'active')
  expect.equal(entry(service, 'settings').enabled, true)
  running.runtime:close()
end)

test('invalid configurations are rejected before disposing the live activation', function()
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
  for _, invalid in { { value = 'invalid' }, { unknown = true }, { value = -1 }, false } do
    expect.raises(function()
      running.service:configure('settings', invalid)
    end, 'managed%-settings')
    expect.equal(entry(running.service, 'settings').state, 'active')
    expect.equal(entry(running.service, 'settings').previousConfig, nil)
  end
  expect.equal(loads, 1)
  expect.equal(releases, 0)
  expect.equal(#testing.takeReports(), 0)
  running.runtime:close()
  expect.equal(releases, 1)
end)

test('start preflights all definitions before any activation and rejects reserved or unknown protected ids', function()
  local initialized = 0
  local definition = configured(function()
    initialized += 1
  end)
  expect.raises(function()
    management.start {
      { id = 'valid', definition = definition },
      {
        id = 'invalid',
        factory = function()
          return definition
        end,
        config = { value = 'invalid' },
      },
    }
  end, 'managed%-settings')
  expect.equal(initialized, 0)
  expect.equal(#testing.takeReports(), 0)
  expect.raises(function()
    management.start { { id = 'composition', definition = definition } }
  end, 'reserved')
  expect.raises(function()
    management.start({ { id = 'valid', definition = definition } }, { protected = { 'missing' } })
  end, 'unknown entry missing')
  expect.equal(initialized, 0)
end)

test('failed changes retain the last working configuration through repeated edits and failed recovery', function()
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
  expect.equal(observed, 2)
  expect.equal(entry(service, 'settings').previousConfig.value, 1)
  service:configure('settings', { value = 9 })
  report 'managed build fails'
  expect.equal(entry(service, 'settings').state, 'failed')
  expect.equal(entry(service, 'settings').previousConfig.value, 2)
  service:configure('settings', { value = 9 })
  report 'managed build fails'
  expect.equal(entry(service, 'settings').previousConfig.value, 2)
  failRecovery = true
  service:recover 'settings'
  report 'managed build fails'
  expect.equal(entry(service, 'settings').state, 'failed')
  expect.equal(entry(service, 'settings').config.value, 2)
  expect.equal(entry(service, 'settings').previousConfig.value, 2, 'failed recovery retains the working configuration')
  failRecovery = false
  service:recover 'settings'
  expect.equal(entry(service, 'settings').state, 'active')
  expect.equal(observed, 2)
  expect.equal(entry(service, 'settings').previousConfig, nil)
  expect.raises(function()
    service:recover 'settings'
  end, 'no previous configuration')
  running.runtime:close()
end)

test('a disabled or initially failed entry never replaces recovery history with an unverified configuration', function()
  local definition = configured(function(_context, settings)
    if settings.value == 9 then
      error('managed unverified build', 0)
    end
  end)
  local running = management.start { { id = 'settings', definition = definition } }
  local service = running.service
  service:configure('settings', { value = 2 })
  service:disable 'settings'
  service:configure('settings', { value = 9 })
  report 'managed unverified build'
  expect.equal(entry(service, 'settings').previousConfig.value, 2)
  service:recover 'settings'
  expect.equal(entry(service, 'settings').state, 'active')
  running.runtime:close()
  local failed = management.start { { id = 'failed', definition = definition, config = { value = 9 } } }
  report 'managed unverified build'
  failed.service:configure('failed', { value = 9 })
  report 'managed unverified build'
  expect.equal(entry(failed.service, 'failed').previousConfig, nil, 'no configuration has activated successfully')
  expect.raises(function()
    failed.service:recover 'failed'
  end, 'no previous configuration')
  failed.runtime:close()
end)

test('a definition without a schema cannot be configured', function()
  local raw = plugin.define { name = 'managed-raw', init = function() end }
  local running = management.start { { id = 'raw', definition = raw } }
  expect.raises(function()
    running.service:configure('raw', { value = 2 })
  end, 'no configuration schema')
  running.runtime:close()
end)

test('removal clears bookkeeping unless cleanup quarantines the entry', function()
  local normal = plugin.define { name = 'managed-normal', init = function() end }
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
  local running = management.start { { id = 'normal', definition = normal }, { id = 'broken', definition = broken } }
  running.service:remove 'normal'
  expect.equal(entry(running.service, 'normal'), nil)
  expect.raises(function()
    running.service:enable 'normal'
  end, 'unknown entry')
  running.service:restore 'normal'
  expect.equal(entry(running.service, 'normal').state, 'active')
  expect.raises(function()
    running.service:remove 'broken'
  end, 'quarantined')
  report 'managed cleanup fails'
  expect.equal(entry(running.service, 'broken').state, 'quarantined')
  expect.truthy(entry(running.service, 'broken').diagnostic:find('managed cleanup fails', 1, true))
  expect.raises(function()
    running.service:restore 'broken'
  end, 'already exists')
  expect.raises(function()
    running.service:reload 'broken'
  end, 'quarantin')
  running.runtime:close()
end)

test('management protection follows dependency bindings and the owners of child providers', function()
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
  local owner, managerOwner
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
      managerOwner = context
      context:require(capability)
    end,
  }
  local running = management.start({
    { id = 'root', definition = root },
    { id = 'parent', definition = parent },
    { id = 'manager', definition = viewer },
  }, { protected = { 'manager' } })
  expect.equal(running.service:ownerId(owner), entry(running.service, 'parent').instanceId)
  expect.equal(running.service:ownerId(managerOwner), entry(running.service, 'manager').instanceId)
  expect.equal(running.service:ownerId {}, nil)
  for _, id in { 'composition', 'root', 'parent', 'manager' } do
    expect.equal(entry(running.service, id).protected, true)
    for _, action in { 'disable', 'reload', 'remove', 'recover' } do
      expect.raises(function()
        running.service[action](running.service, id)
      end, 'cannot be changed')
    end
    expect.raises(function()
      running.service:configure(id, {})
    end, 'cannot be changed')
  end
  local ownerId = running.service:ownerId(owner)
  running.runtime:close()
  expect.equal(running.service:ownerId(owner), ownerId, 'closing retains exact owner identity')
  expect.equal(owner:active(), false, 'owner inspection grants no activation authority')
end)

test('service inspection is detached immutable and does not drain runtime intent', function()
  local definition = configured(function() end)
  local config = { value = 3 }
  local running = management.start { { id = 'settings', definition = definition, config = config } }
  local entries, snapshot = running.service:entries(), running.service:snapshot()
  config.value = 10
  expect.equal(entry(running.service, 'settings').config.value, 3)
  expect.truthy(table.isfrozen(entries) and table.isfrozen(entries[2]) and table.isfrozen(entries[2].config))
  expect.truthy(table.isfrozen(running.service))
  expect.raises(function()
    entries[2].config.value = 6
  end, 'readonly')
  expect.raises(function()
    snapshot.instances[1].enabled = false
  end)
  running.service:configure('settings', { value = 7 })
  expect.equal(entries[2].config.value, 3)
  expect.equal(snapshot.instances[2].state, 'active')
  running.runtime:close()
end)

test('malformed composition input and recursive containers fail before activation', function()
  local initialized = 0
  local definition = configured(function()
    initialized += 1
  end)
  for _, entries in
    {
      { { id = 'duplicate', definition = definition }, { id = 'duplicate', definition = definition } },
      { { id = 'unknown', definition = definition, extra = true } },
      {
        {
          id = 'both',
          definition = definition,
          factory = function()
            return definition
          end,
        },
      },
      { { id = 'bad-config', definition = definition, config = false } },
      { named = { id = 'named', definition = definition } },
    }
  do
    expect.raises(function()
      management.start(entries)
    end)
  end
  local recursive = {}
  recursive.self = recursive
  expect.raises(function()
    management.start { { id = 'recursive', definition = definition, config = recursive } }
  end, 'recursive table')
  for _, options in { { extra = true }, { protected = false }, { protected = { 1 } } } do
    expect.raises(function()
      management.start({ { id = 'valid', definition = definition } }, options)
    end)
  end
  expect.equal(initialized, 0)
end)

test('a runtime callback can inspect management but cannot reenter an entry change', function()
  local observed
  local viewer = plugin.define {
    name = 'managed-reentrant-viewer',
    requires = { composition = composition.capability },
    init = function(context)
      local service = context:require(composition.capability)
      observed = service:entries()
      expect.raises(function()
        service:remove 'viewer'
      end, 'runtime is draining')
    end,
  }
  local running = management.start { { id = 'viewer', definition = viewer } }
  expect.truthy(observed and table.isfrozen(observed))
  expect.equal(entry(running.service, 'viewer').state, 'active')
  running.runtime:close()
end)

test('provider outages retain the factory definition and composed configuration', function()
  local capability = plugin.capability { name = 'local/managed-composed-provider', schema = 1 }
  local provider = plugin.define {
    name = 'managed-composed-provider',
    provides = { service = capability },
    init = function(_context, _config, publisher)
      publisher:provide(capability, {})
    end,
  }
  local made, loads, received = 0, 0, nil
  local consumer = plugin.consumer {
    name = 'managed-composed-dependent',
    requires = { service = capability },
    schema = schema.object { map = schema.default(schema.map(schema.string())) {} },
    init = function(context, settings)
      context:require(capability)
      loads += 1
      received = settings.map
    end,
  }
  local entries = plugin.compose {
    { id = 'provider', definition = provider },
    {
      id = 'dependent',
      factory = function()
        made += 1
        return consumer.definition
      end,
      config = { map = { old = 'old' } },
    },
  }
  entries = plugin.compose(entries, { { id = 'dependent', config = { map = {} } } })
  local running = management.start(entries)
  local started = made
  expect.equal(next(received), nil)
  running.service:disable 'provider'
  expect.equal(entry(running.service, 'dependent').state, 'inactive')
  running.service:enable 'provider'
  expect.equal(entry(running.service, 'dependent').state, 'active')
  expect.equal(next(received), nil)
  expect.equal(loads, 2)
  expect.equal(made, started, 'provider recovery retains the source definition')
  running.runtime:close()
end)

return test
