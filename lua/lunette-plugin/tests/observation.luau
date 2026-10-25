-- Checks compact composition observation against fresh inspection data and its steady-state allocation cost.

local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local management = require '@lunette-plugin/management'
local schema = require '@lunette-plugin/schema'
local test = testing.suite()

local function configured(): adapter.Definition<{ value: number? }>
  return plugin.consumer({
    name = 'observed-settings',
    schema = schema.object { value = schema.default(schema.number())(1) },
    init = function() end,
  }).definition
end

test('observation tracks configuration values, enabled intent, removal, and restoration', function()
  local running = management.start { { id = 'settings', definition = configured(), config = { value = 1 } } }
  local service = running.service
  local initial = service:observe { 'missing/toolkit' }
  expect.equal(initial.missing[1], 'missing/toolkit')
  expect.raises(function()
    initial.missing[1] = 'changed'
  end, 'readonly')
  expect.raises(function()
    initial.revision = 0
  end, 'readonly')
  expect.equal(service:observe({}).revision, initial.revision, 'queries do not change the composition')
  expect.equal(service:observe({}).entries, initial.entries, 'unchanged polls reuse compact values')
  expect.raises(function()
    initial.entries[1].enabled = false
  end, 'readonly')
  service:configure('settings', { value = 1 })
  expect.equal(service:observe({}).revision, initial.revision, 'equal configuration keeps the healthy stretch')
  service:configure('settings', { value = 2 })
  local changed = service:observe({}).revision
  expect.truthy(changed ~= initial.revision, 'configuration changes restart the healthy stretch')
  service:disable 'settings'
  local disabled = service:observe({}).revision
  expect.truthy(disabled ~= changed, 'enabled intent changes restart the healthy stretch')
  service:enable 'settings'
  expect.truthy(service:observe({}).revision ~= disabled)
  service:remove 'settings'
  local removed = service:observe({}).revision
  service:restore 'settings'
  expect.truthy(service:observe({}).revision ~= removed)
  expect.equal(initial.missing[1], 'missing/toolkit', 'old observations remain detached')
  running.runtime:close()
end)

test('an observation first read after shutdown remains immutable', function()
  local running = management.start {}
  running.runtime:close()
  local closed = running.service:observe {}
  expect.equal(closed.closed, true)
  expect.equal(#closed.entries, 0)
  expect.raises(function()
    closed.entries[1] = {}
  end, 'readonly')
end)

test('observation includes active child providers and follows native lifecycle failures', function()
  local capability = plugin.capability { name = 'observed/child', version = 1 }
  local fail = false
  local cleanupFails = false
  local childDefinition = adapter.define {
    name = 'observed-child',
    provides = { capability },
    init = function(context: adapter.Context, _config: {}, publish: adapter.Publisher)
      if fail then
        error('observed child load fails', 0)
      end
      context:effect(function(): () -> ()
        return function()
          if cleanupFails then
            error('observed child cleanup fails', 0)
          end
        end
      end)
      publish:provide(capability, {})
    end,
  }
  local parent = adapter.define {
    name = 'observed-parent',
    init = function(context: adapter.Context)
      context:child(childDefinition, {})
    end,
  }
  local running = management.start { { id = 'parent', definition = parent } }
  local service = running.service
  local initial = service:observe { 'observed/child' }
  expect.equal(#initial.missing, 0, 'child providers count')
  fail = true
  service:reload 'parent'
  expect.equal(service:observe({ 'observed/child' }).missing[1], 'observed/child')
  expect.equal(service:observe({}).revision, initial.revision, 'child state is not entry configuration')
  testing.takeReports()
  fail = false
  service:reload 'parent'
  expect.equal(#service:observe({ 'observed/child' }).missing, 0)
  service:disable 'parent'
  expect.equal(
    service:observe({ 'observed/child' }).missing[1],
    'observed/child',
    'removed child providers do not count'
  )
  service:enable 'parent'
  cleanupFails = true
  service:disable 'parent'
  expect.equal(service:observe({ 'observed/child' }).missing[1], 'observed/child', 'quarantined providers do not count')
  testing.takeReports()
  running.runtime:close()
end)

test('observation follows structural configuration equality and entry ordering', function()
  local definition = adapter.define { name = 'observed-values', init = function() end }
  local running = management.start {
    { id = 'first', definition = definition, config = { nested = { value = 1 }, values = { 2, 3 } } },
    { id = 'second', definition = definition },
  }
  local service = running.service
  local before = service:observe({}).revision
  service:reload 'first'
  expect.equal(service:observe({}).revision, before, 'cloned nested tables compare by value')
  service:remove 'first'
  service:restore 'first'
  expect.truthy(service:observe({}).revision ~= before, 'restoring the first entry changes entry order')
  running.runtime:close()
end)

test('observation detects live configuration saved by an entry', function()
  local context
  local definition = plugin.consumer({
    name = 'observed-saved-settings',
    schema = schema.object { value = schema.default(schema.number())(1) },
    init = function(current: adapter.Context)
      context = current
    end,
  }).definition
  local running = management.start({ { id = 'settings', definition = definition } }, {
    saved = {
      overrides = {},
      write = function() end,
      report = function(message: string)
        error(message, 0)
      end,
      storable = function(): boolean
        return true
      end,
    },
  })
  local before = running.service:observe({}).revision
  expect.equal(context:save { value = 2 }, true)
  local changed = running.service:observe({}).revision
  expect.truthy(changed ~= before, 'entry-owned saves restart the healthy stretch')
  context:save { value = 2 }
  expect.equal(running.service:observe({}).revision, changed, 'equal saved values preserve the healthy stretch')
  running.runtime:close()
end)

test('observation remains reentrant while composition changes drain', function()
  local composition = require '@lunette-contracts/composition'
  local service
  local observations = {}
  local definition = adapter.define {
    name = 'observed-reentrant',
    requires = { composition.capability },
    init = function(context: adapter.Context)
      service = context:require(composition.capability)
      observations[#observations + 1] = service:observe {}
      context:effect(function(): () -> ()
        return function()
          observations[#observations + 1] = service:observe {}
        end
      end)
    end,
  }
  local running = management.start { { id = 'entry', definition = definition } }
  expect.equal(observations[1].draining, true, 'load observation does not recurse into drain')
  local initial = service:observe({}).revision
  service:reload 'entry'
  expect.equal(service:observe({}).revision, initial, 'reload alone preserves values')
  service:disable 'entry'
  expect.truthy(service:observe({}).revision ~= initial)
  for _, observation in observations do
    expect.equal(observation.draining, true, 'load and cleanup run inside drain')
  end
  running.runtime:close()
end)

test('unchanged observation allocates a bounded result instead of full runtime inspection', function()
  local definition = configured()
  local entries = {}
  for index = 1, 80 do
    entries[index] = { id = `settings-{index}`, definition = definition, config = { value = index } }
  end
  local running = management.start(entries)
  local service = running.service
  local toolkit = { 'missing/toolkit' }
  service:observe(toolkit)
  local function allocation(read: () -> ()): number
    collectgarbage 'collect'
    collectgarbage 'stop'
    local before = collectgarbage 'count'
    for _ = 1, 20 do
      read()
    end
    local kib = collectgarbage 'count' - before
    collectgarbage 'restart'
    return kib
  end
  local observation = allocation(function()
    service:observe(toolkit)
  end)
  local inspection = allocation(function()
    service:snapshot()
    service:entries()
  end)
  expect.truthy(observation < 32, `20 compact observations allocate {observation} KiB`)
  expect.truthy(observation * 20 < inspection, `compact {observation} KiB; inspection {inspection} KiB`)
  running.runtime:close()
end)

return test
