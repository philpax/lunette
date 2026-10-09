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
  expect.equal(initial[2].schema, definition.schema)
  expect.equal(initial[2].definition, nil)
  expect.equal(initial[2].config, nil)
  expect.equal(initial[2].instance, nil)
  local duplicate = running.runtime:use(definition, {})
  expect.raises(function()
    duplicate:enable()
  end, nil, 'the original provider reserves its contract')
  duplicate:dispose()
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

return test
