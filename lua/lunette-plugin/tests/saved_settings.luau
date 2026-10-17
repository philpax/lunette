-- Exercises saved settings in session composition management against the native plugin runtime.

local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local management = require '@lunette-plugin/management'
local composition = require '@lunette-contracts/composition'
local schema = require '@lunette-plugin/schema'
local test = testing.suite()

type Settings = { value: number, label: string }
type Memory = management.Saved & { writes: number, reports: { string } }

-- Saved settings kept in memory, counting writes and collecting reports.
local function memory(overrides: { [string]: { [string]: unknown } }?): Memory
  local saved = { overrides = overrides or {}, writes = 0, reports = {} } :: any
  saved.write = function(): ()
    saved.writes += 1
  end
  saved.report = function(message: string): ()
    table.insert(saved.reports, message)
  end
  saved.storable = function(value: unknown): boolean
    return type(value) ~= 'function'
  end
  return saved
end

-- A plugin with a number and a label that records each start, and that fails to start while its value is 13.
local function settings(starts: { Settings }, contexts: { adapter.Context }?): adapter.Definition<any>
  return plugin.consumer({
    name = 'saved-settings',
    schema = schema.object {
      value = schema.default(schema.number { integer = true, minimum = 0 })(1),
      label = schema.default(schema.string()) 'plain',
    },
    init = function(context: adapter.Context, current: Settings)
      if current.value == 13 then
        error('thirteen does not start', 0)
      end
      table.insert(starts, current)
      if contexts then
        table.insert(contexts, context)
      end
    end,
  }).definition
end

local function status(service: composition.Service, id: string, field: string): composition.SavedStatus?
  for _, setting in service:savedSettings() do
    if setting.id == id and setting.field == field then
      return setting.status
    end
  end
  return nil
end

test('saved fields apply over the configuration, and configuring records only what differs from it', function()
  testing.native()
  local starts: { Settings } = {}
  local saved = memory { settings = { value = 5 } }
  local running = management.start(
    { { id = 'settings', definition = settings(starts), config = { value = 2, label = 'base' } } },
    { saved = saved }
  )
  local service = running.service
  expect.equal(starts[1].value, 5, 'the saved value wins over the configured one')
  expect.equal(starts[1].label, 'base', 'an unsaved field keeps its configured value')
  local entry = service:entries()[2]
  expect.equal((entry.baseConfig :: any).value, 2, 'the entry reports its configured value')
  expect.equal(status(service, 'settings', 'value'), 'applied')

  service:configure('settings', { value = 2, label = 'changed' })
  expect.equal(saved.overrides.settings.label, 'changed', 'a changed field is saved')
  expect.equal(saved.overrides.settings.value, nil, 'a field set back to its configured value is no longer saved')
  expect.truthy(saved.writes > 0, 'the change is written')
  service:configure('settings', { value = 2, label = 'base' })
  expect.equal(saved.overrides.settings, nil, 'an entry with nothing saved leaves the file')
  running.runtime:close()
end)

test('an invalid saved field is reported and kept, and the valid ones still apply', function()
  testing.native()
  local starts: { Settings } = {}
  local saved = memory {
    settings = { value = -4, label = 'kept' },
    gone = { anything = true },
  }
  local running = management.start({ { id = 'settings', definition = settings(starts) } }, { saved = saved })
  local service = running.service
  expect.equal(starts[1].value, 1, 'the invalid value does not apply')
  expect.equal(starts[1].label, 'kept', 'the valid label does')
  expect.equal(#saved.reports, 1, table.concat(saved.reports, '\n'))
  expect.truthy(saved.reports[1]:find('settings setting value', 1, true), saved.reports[1])
  expect.equal(status(service, 'settings', 'value'), 'invalid')
  expect.equal(status(service, 'settings', 'label'), 'applied')
  expect.equal(status(service, 'gone', 'anything'), 'unused', 'an entry that is not composed keeps its fields')
  service:configure('settings', { label = 'again' })
  expect.equal(saved.overrides.settings.value, -4, 'recording keeps the invalid field in the file')
  expect.equal(saved.overrides.gone.anything, true, 'and the fields of entries that are not composed')
  running.runtime:close()
end)

test("a plugin saves its own changes without restarting, and the entry's schema checks them", function()
  testing.native()
  local starts: { Settings } = {}
  local contexts: { adapter.Context } = {}
  local saved = memory()
  local running = management.start({ { id = 'settings', definition = settings(starts, contexts) } }, { saved = saved })
  expect.equal(contexts[1]:save { label = 'live' }, true, 'the runtime keeps saved settings')
  expect.equal(saved.overrides.settings.label, 'live', 'the change is saved')
  expect.equal(#starts, 1, 'the entry was not restarted')
  expect.equal((running.service:entries()[2].config :: any).label, 'live', 'the configuration holds the change')
  expect.raises(function()
    contexts[1]:save { value = 'many' }
  end, 'value')
  expect.equal(saved.overrides.settings.value, nil, 'a change that fails the schema is not saved')
  expect.equal(contexts[1]:save { label = 'plain' }, true)
  expect.equal(saved.overrides.settings, nil, 'a field saved back to its schema default is no longer saved')
  running.runtime:close()

  local alone = adapter.runtime()
  local loose: { adapter.Context } = {}
  alone:use(settings({}, loose), {}):enable()
  alone:drain()
  expect.equal(loose[1]:save { label = 'nowhere' }, false, 'a runtime without saved settings saves nothing')
  alone:close()
end)

test('an entry that fails to start with its saved fields starts without them, and forgetting them clears it', function()
  testing.native()
  local starts: { Settings } = {}
  local saved = memory { settings = { value = 13 } }
  local running = management.start({ { id = 'settings', definition = settings(starts) } }, { saved = saved })
  local service = running.service
  local failures = testing.takeReports()
  expect.equal(#failures, 1, 'the failed start is reported')
  expect.truthy(failures[1]:find('thirteen does not start', 1, true), failures[1])
  expect.equal(service:entries()[2].state, 'active', 'the entry runs')
  expect.equal(starts[#starts].value, 1, 'with its configured value')
  expect.equal(status(service, 'settings', 'value'), 'suspended')
  expect.truthy(saved.reports[1]:find('failed to start with its saved settings', 1, true), saved.reports[1])
  expect.equal(saved.overrides.settings.value, 13, 'the saved field stays until it is reset')
  service:forgetSaved('settings', 'value')
  expect.equal(saved.overrides.settings, nil, 'forgetting removes the field')
  expect.equal(#service:savedSettings(), 0, 'and the entry has no saved settings left')
  running.runtime:close()
end)

test('forgetting a saved field returns the entry to its configuration with the fields that remain', function()
  testing.native()
  local starts: { Settings } = {}
  local saved = memory { settings = { value = 7, label = 'saved' } }
  local running = management.start(
    { { id = 'settings', definition = settings(starts), config = { value = 2 } } },
    { saved = saved }
  )
  running.service:forgetSaved('settings', 'value')
  expect.equal(starts[#starts].value, 2, 'the configured value returns')
  expect.equal(starts[#starts].label, 'saved', 'the remaining saved field still applies')
  running.service:forgetSaved 'settings'
  expect.equal(starts[#starts].label, 'plain', 'forgetting the entry returns every field')
  expect.equal(saved.overrides.settings, nil)
  running.runtime:close()
end)

test('a value the file cannot hold is reported and not saved', function()
  testing.native()
  local contexts: { adapter.Context } = {}
  local saved = memory()
  local definition = plugin.consumer({
    name = 'callback-settings',
    schema = schema.object { run = schema.optional(schema.callback(function() end)) },
    init = function(context: adapter.Context)
      table.insert(contexts, context)
    end,
  }).definition
  local running = management.start({ { id = 'callbacks', definition = definition } }, { saved = saved })
  contexts[1]:save { run = function() end }
  expect.equal(saved.overrides.callbacks, nil, 'the callback is not saved')
  expect.truthy(saved.reports[1]:find('cannot be saved', 1, true), saved.reports[1])
  running.runtime:close()
end)

return test
