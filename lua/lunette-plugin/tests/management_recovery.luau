-- Covers accepted reload failures and schema-directed recovery snapshots.

local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local schema = require '@lunette-plugin/schema'
local fixture = require './support/management_fixture'
local entry, configured = fixture.entry, fixture.configured
local test = testing.suite()

test('an accepted replacement keeps configuration and recovery history when draining exceeds its budget', function()
  local looping, child, observed = true, nil, nil
  local loopDefinition = plugin.define {
    name = 'managed-drain-loop',
    init = function()
      if looping and child then
        child:reload {}
      end
    end,
  }
  local definition = configured(function(context, settings)
    observed = settings.value
    if settings.value == 2 then
      child = context:child(loopDefinition, {})
    end
  end)
  local running = management.start { { id = 'settings', definition = definition, config = { value = 1 } } }
  expect.raises(function()
    running.service:configure('settings', { value = 2 })
  end, 'plugin drain: stopped after')
  expect.equal(observed, 2, 'the parent activated with the accepted configuration')
  local accepted = entry(running.service, 'settings')
  expect.equal(accepted.config.value, 2)
  expect.equal(accepted.previousConfig.value, 1)
  expect.equal(accepted.state, 'active')
  local parent
  for _, node in running.service:snapshot().instances do
    if node.id == accepted.instanceId then
      parent = node
    end
  end
  expect.equal(parent.state, 'active')
  looping = false
  running.runtime:drain()
  expect.equal(entry(running.service, 'settings').config.value, 2)
  running.service:recover 'settings'
  expect.equal(observed, 1)
  expect.equal(entry(running.service, 'settings').config.value, 1)
  expect.equal(entry(running.service, 'settings').previousConfig, nil)
  running.runtime:close()
end)

test('an accepted removal remains restorable when unrelated lifecycle work exceeds the drain budget', function()
  local looping, child = true, nil
  local loopDefinition = plugin.define {
    name = 'managed-remove-drain-loop',
    init = function()
      if looping and child then
        child:reload {}
      end
    end,
  }
  local definition = configured(function(context, settings)
    if settings.value == 2 then
      child = context:child(loopDefinition, {})
    end
  end)
  local tail = plugin.define { name = 'managed-removable-tail', init = function() end }
  local running = management.start {
    { id = 'settings', definition = definition, config = { value = 1 } },
    { id = 'tail', definition = tail },
  }
  local originalId = entry(running.service, 'tail').instanceId
  expect.raises(function()
    running.service:configure('settings', { value = 2 })
  end, 'plugin drain: stopped after')
  expect.raises(function()
    running.service:remove 'tail'
  end, 'plugin drain: stopped after')
  looping = false
  running.runtime:drain()
  expect.equal(entry(running.service, 'tail'), nil)
  expect.equal(fixture.knownEntry(running.service, 'tail').installed, false)
  running.service:restore 'tail'
  local restored = entry(running.service, 'tail')
  expect.equal(restored.state, 'active')
  expect.truthy(restored.instanceId ~= originalId)
  running.runtime:close()
end)

test('union snapshots copy only the accepted structured arm and preserve actual custom tokens', function()
  local opaque = { marker = true }
  local custom = schema.custom {
    runtimeType = 'table',
    validate = function(value)
      if value ~= opaque then
        error('not the designated opaque token', 0)
      end
      return value
    end,
  }
  local ordinary = schema.object {
    value = schema.number(),
    inherited = schema.default(schema.number())(11),
  }
  local choice = schema.union(ordinary, custom)
  local branched = schema.union(
    schema.object { kind = schema.literal 'ordinary', payload = ordinary },
    schema.object { kind = schema.literal 'opaque', payload = custom }
  )
  local received
  local definition = plugin.consumer({
    name = 'managed-union-snapshots',
    schema = schema.object {
      choice = schema.default(choice) { value = 1 },
      branched = schema.default(branched) { kind = 'ordinary', payload = { value = 1 } },
    },
    init = function(_context, settings)
      received = settings
    end,
  }).definition
  local original = { choice = { value = 3 }, branched = { kind = 'ordinary', payload = { value = 4 } } }
  local running = management.start { { id = 'settings', definition = definition, config = original } }
  local initial = entry(running.service, 'settings')
  original.choice.value = 30
  original.branched.payload.value = 40
  expect.equal(initial.config.choice.value, 3)
  expect.equal(initial.config.branched.payload.value, 4)
  expect.equal(initial.config.choice.inherited, nil, 'the raw override does not become resolved settings')
  expect.equal(received.choice.inherited, 11)
  expect.raises(function()
    initial.config.choice.value = 99
  end, 'readonly')
  expect.raises(function()
    initial.config.branched.payload.value = 99
  end, 'readonly')
  local changed = { choice = { value = 5 }, branched = { kind = 'ordinary', payload = { value = 6 } } }
  running.service:configure('settings', changed)
  changed.choice.value = 50
  changed.branched.payload.value = 60
  local current = entry(running.service, 'settings')
  expect.equal(current.config.choice.value, 5)
  expect.equal(current.config.branched.payload.value, 6)
  expect.equal(current.previousConfig.choice.value, 3)
  expect.equal(current.previousConfig.branched.payload.value, 4)
  expect.raises(function()
    current.previousConfig.branched.payload.value = 99
  end, 'readonly')
  running.service:recover 'settings'
  expect.equal(received.choice.value, 3)
  expect.equal(received.branched.payload.value, 4)
  running.service:configure('settings', { choice = opaque, branched = { kind = 'opaque', payload = opaque } })
  expect.equal(received.choice, opaque)
  expect.equal(received.branched.payload, opaque)
  expect.equal(entry(running.service, 'settings').config.choice, opaque)
  expect.equal(entry(running.service, 'settings').config.branched.payload, opaque)
  running.service:recover 'settings'
  expect.equal(received.choice.value, 3)
  expect.equal(received.branched.payload.value, 4)
  expect.equal(initial.config.choice.value, 3, 'earlier snapshots remain detached through recovery')
  running.runtime:close()
end)

return test
