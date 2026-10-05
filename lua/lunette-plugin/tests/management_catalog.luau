-- Exercises retained session definitions, restoration, and catalog snapshots against the native runtime.

local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local schema = require '@lunette-plugin/schema'
local fixture = require './support/management_fixture'
local entry, knownEntry = fixture.entry, fixture.knownEntry
local configured, report = fixture.configured, fixture.report
local test = testing.suite()

test('the catalog restores removed definitions with their latest configuration and new instance ids', function()
  local factories, builds, releases = 0, 0, 0
  local custom = { marker = true }
  local received
  local capability = plugin.capability { name = 'local/managed-catalog-settings', schema = 1 }
  local definition = plugin.provider({
    name = 'managed-catalog-settings',
    capability = capability,
    schema = schema.object {
      value = schema.default(schema.number { integer = true })(1),
      custom = schema.default(schema.custom {
        runtimeType = 'table',
        validate = function(value)
          expect.equal(value, custom)
          return value
        end,
      })(custom),
    },
    build = function(context, settings)
      received = settings
      builds += 1
      context:effect(function()
        return function()
          releases += 1
        end
      end)
      return settings
    end,
  }).definition
  local running = management.start {
    {
      id = 'settings',
      factory = function()
        factories += 1
        return definition
      end,
      config = { custom = custom },
    },
    { id = 'tail', definition = plugin.define { name = 'managed-catalog-tail', init = function() end } },
  }
  local service = running.service
  local initial = service:catalog()
  expect.equal(initial[1].id, 'composition')
  expect.equal(initial[2].id, 'settings')
  expect.equal(initial[3].id, 'tail')
  expect.equal(initial[2].installed, true)
  expect.equal(initial[2].configurable, true)
  expect.equal(initial[2].schema, definition.schema)
  expect.equal(initial[2].definition, nil)
  expect.equal(initial[2].config, nil)
  expect.equal(initial[2].instance, nil)
  local duplicate = running.runtime:use(definition, {})
  expect.raises(function()
    duplicate:enable()
  end, nil, 'the original provider reserves its contract')
  duplicate:dispose()
  expect.raises(function()
    service:add {
      id = 'settings',
      factory = function()
        factories += 1
        return definition
      end,
    }
  end, 'already exists')
  expect.equal(factories, 1, 'duplicate installed ids do not run a factory')
  service:configure('settings', { value = 7, custom = custom })
  local originalId = entry(service, 'settings').instanceId
  service:remove 'settings'
  expect.equal(entry(service, 'settings'), nil)
  expect.equal(knownEntry(service, 'settings').installed, false)
  expect.equal(service:catalog()[2].id, 'settings', 'removal preserves catalog order')
  expect.equal(initial[2].installed, true, 'earlier inspection remains unchanged')
  expect.truthy(table.isfrozen(initial) and table.isfrozen(initial[2]))
  expect.raises(function()
    initial[2].installed = false
  end, 'readonly')
  service:restore 'settings'
  local restored = entry(service, 'settings')
  expect.truthy(restored.instanceId ~= originalId)
  expect.equal(restored.state, 'active')
  expect.equal(restored.config.value, 7)
  expect.equal(restored.config.custom, custom)
  expect.equal(received.custom, custom)
  expect.equal(received.value, 7)
  expect.equal(restored.schema, definition.schema, 'restoration retains the original definition metadata')
  expect.equal(factories, 1, 'restoration never runs the factory again')
  expect.equal(builds, 3)
  expect.equal(releases, 2)
  expect.equal(knownEntry(service, 'settings').installed, true)
  expect.equal(service:catalog()[2].id, 'settings')
  local restoredDuplicate = running.runtime:use(definition, {})
  expect.raises(function()
    restoredDuplicate:enable()
  end, nil, 'the restored provider reserves its original contract')
  restoredDuplicate:dispose()
  expect.raises(function()
    service:restore 'settings'
  end, 'already exists')
  expect.raises(function()
    service:restore '@unknown/arbitrary-path'
  end, 'unknown entry')
  running.runtime:close()
end)

test('restore and explicit source replacement reject invalid preflight without changing catalog history', function()
  local reject, builds, factories = false, 0, 0
  local original = plugin.consumer({
    name = 'managed-catalog-original',
    schema = schema.object { value = schema.default(schema.number())(1) },
    validate = function()
      if reject then
        error('catalog validation rejects restore', 0)
      end
    end,
    init = function()
      builds += 1
    end,
  }).definition
  local running = management.start {}
  local service = running.service
  service:add {
    id = 'known',
    factory = function()
      factories += 1
      return original
    end,
    config = { value = 4 },
  }
  service:remove 'known'
  local removed = knownEntry(service, 'known')
  reject = true
  expect.raises(function()
    service:restore 'known'
  end, 'catalog validation rejects restore')
  expect.equal(entry(service, 'known'), nil)
  expect.equal(knownEntry(service, 'known').installed, false)
  expect.equal(knownEntry(service, 'known').name, removed.name)
  expect.equal(#service:snapshot().instances, 1)
  local replacement = configured(function() end)
  expect.raises(function()
    service:add { id = 'known', definition = replacement, config = { value = 'invalid' } }
  end, 'managed%-settings')
  expect.raises(function()
    service:add {
      id = 'known',
      factory = function()
        return {}
      end,
    }
  end, 'definition')
  expect.raises(function()
    service:add {
      id = 'known',
      factory = function()
        return { name = 'not-a-native-definition' }
      end,
    }
  end, 'definition')
  expect.equal(knownEntry(service, 'known').name, original.name)
  expect.equal(knownEntry(service, 'known').schema, original.schema)
  reject = false
  service:restore 'known'
  expect.equal(entry(service, 'known').config.value, 4)
  expect.equal(factories, 1)
  expect.equal(builds, 2)
  service:remove 'known'
  service:add { id = 'known', definition = replacement, config = { value = 8 } }
  expect.equal(knownEntry(service, 'known').name, replacement.name)
  expect.equal(removed.name, original.name, 'previous catalog snapshots keep the old metadata')
  expect.equal(#service:catalog(), 2, 'replacement reuses the catalog position')
  service:remove 'known'
  service:restore 'known'
  expect.equal(entry(service, 'known').config.value, 8)
  running.runtime:close()
end)

test('invalid changes and quarantine retain known catalog entries and their reservations', function()
  local definition = configured(function() end)
  local running = management.start { { id = 'settings', definition = definition, config = { value = 3 } } }
  local service = running.service
  expect.raises(function()
    service:configure('settings', { value = 'invalid' })
  end, 'managed%-settings')
  service:remove 'settings'
  service:restore 'settings'
  expect.equal(entry(service, 'settings').config.value, 3, 'invalid configuration never replaces retained history')
  local broken = plugin.define {
    name = 'managed-catalog-quarantine',
    init = function(context)
      context:effect(function()
        return function()
          error('catalog cleanup fails', 0)
        end
      end)
    end,
  }
  service:add { id = 'broken', definition = broken }
  local before = knownEntry(service, 'broken')
  expect.raises(function()
    service:remove 'broken'
  end, 'quarantined')
  report 'catalog cleanup fails'
  expect.equal(knownEntry(service, 'broken').installed, true)
  expect.equal(knownEntry(service, 'broken').name, before.name)
  expect.equal(entry(service, 'broken').state, 'quarantined')
  expect.raises(function()
    service:restore 'broken'
  end, 'already exists')
  expect.raises(function()
    service:add { id = 'broken', definition = definition }
  end, 'already exists')
  expect.equal(knownEntry(service, 'broken').name, broken.name)
  expect.equal(#service:catalog(), 3)
  running.runtime:close()
end)

return test
