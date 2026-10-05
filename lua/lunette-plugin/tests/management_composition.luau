-- Covers composed entries at management's startup and addition boundaries against the real runtime.

local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local schema = require '@lunette-plugin/schema'
local lunette = require '@lunette'
local fixture = require './support/management_fixture'
local entry, knownEntry = fixture.entry, fixture.knownEntry
local test = testing.suite()

for _, boundary in { 'start', 'add' } do
  test(boundary .. ' resolves factory patches before preflight and retains detached recovery configuration', function()
    local made, received = 0, nil
    local plain, cycle, originalCycle = { marker = 'plain' }, {}, {}
    cycle.self, originalCycle.self = cycle, originalCycle
    local opaque = schema.custom {
      runtimeType = 'table',
      validate = function(value)
        if value ~= plain and value ~= cycle and value ~= originalCycle then
          error('managed custom identity changed', 0)
        end
        return value
      end,
    }
    local consumer = plugin.consumer {
      name = 'managed-composed-' .. boundary,
      schema = schema.object {
        object = schema.default(schema.object {
          first = schema.default(schema.number())(1),
          second = schema.default(schema.number())(2),
          inherited = schema.default(schema.number())(11),
        }) {},
        map = schema.default(schema.map(schema.string())) {},
        plain = schema.default(opaque)(plain),
        cycle = schema.default(opaque)(originalCycle),
      },
      init = function(_context, settings)
        received = settings
      end,
    }
    local original = {
      object = { first = 3, second = 4 },
      map = { old = 'old' },
      plain = plain,
      cycle = originalCycle,
    }
    local firstPatch = { object = { first = 8 }, map = { fresh = 'fresh' }, cycle = cycle }
    local emptyPatch = { object = {}, map = {} }
    local entries = plugin.compose {
      {
        id = 'settings',
        factory = function()
          made += 1
          return consumer.definition
        end,
        config = original,
      },
    }
    entries = plugin.compose(entries, { { id = 'settings', config = firstPatch } })
    entries = plugin.compose(entries, { { id = 'settings', config = emptyPatch } })
    entries = plugin.compose(entries)
    original.object.second = 40
    firstPatch.object.first = 80
    emptyPatch.map.later = 'later'
    expect.equal(made, 0, 'composition leaves the factory deferred')
    local running = if boundary == 'start' then management.start(entries) else management.start {}
    if boundary == 'add' then
      running.service:add(entries[1])
    end
    local initial = entry(running.service, 'settings')
    expect.equal(initial.state, 'active')
    expect.equal(made, 1)
    expect.equal(received.object.first, 8)
    expect.equal(received.object.second, 4, 'object patches merge across separate compositions')
    expect.equal(received.object.inherited, 11)
    expect.equal(next(received.map), nil, 'the final empty map replaces both earlier maps')
    expect.equal(received.plain, plain)
    expect.equal(received.cycle, cycle)
    expect.equal(received.cycle.self, cycle)
    expect.equal(initial.config.object.inherited, nil, 'management retains raw overrides rather than resolved settings')
    expect.equal(initial.config.plain, plain)
    expect.equal(initial.config.cycle, cycle)
    expect.falsy(rawequal(initial.config, entries[1].config), 'management owns a detached structural snapshot')
    expect.truthy(table.isfrozen(initial.config.object) and table.isfrozen(initial.config.map))
    expect.falsy(table.isfrozen(plain) or table.isfrozen(cycle))
    running.service:disable 'settings'
    running.service:enable 'settings'
    running.service:reload 'settings'
    expect.equal(made, 1, 'reactivation and reload retain the resolved definition')
    local changed = {
      object = { first = 5, second = 6 },
      map = { changed = 'changed' },
      plain = plain,
      cycle = cycle,
    }
    running.service:configure('settings', changed)
    changed.object.first = 50
    changed.map.changed = 'mutated'
    local current = entry(running.service, 'settings')
    expect.equal(current.config.object.first, 5)
    expect.equal(current.config.map.changed, 'changed')
    expect.equal(current.previousConfig.object.first, 8)
    expect.equal(current.previousConfig.object.second, 4)
    expect.equal(next(current.previousConfig.map), nil)
    expect.equal(current.previousConfig.plain, plain)
    expect.equal(current.previousConfig.cycle, cycle)
    expect.falsy(rawequal(current.config.object, changed.object))
    expect.truthy(table.isfrozen(current.previousConfig.object) and table.isfrozen(current.previousConfig.map))
    expect.raises(function()
      current.previousConfig.object.first = 99
    end, 'readonly')
    running.service:recover 'settings'
    expect.equal(received.object.first, 8)
    expect.equal(received.object.second, 4)
    expect.equal(next(received.map), nil)
    expect.equal(received.plain, plain)
    expect.equal(received.cycle, cycle)
    expect.equal(entry(running.service, 'settings').previousConfig, nil)
    expect.equal(initial.config.object.first, 8, 'earlier snapshots survive later changes and recovery')
    expect.equal(made, 1, 'recovery does not rerun the factory')
    running.runtime:close()
    local second = management.start(entries)
    expect.equal(made, 2, 'each separate start resolves the factory once')
    expect.equal(received.object.first, 8)
    expect.equal(next(received.map), nil)
    second.runtime:close()
  end)

  test(boundary .. ' preserves caller-owned default-wrapped custom root configuration', function()
    local default, config, received, made = {}, {}, nil, 0
    local consumer = plugin.consumer {
      name = 'managed-custom-root-' .. boundary,
      schema = schema.default(schema.custom {
        runtimeType = 'table',
        validate = function(value)
          return value
        end,
      })(default),
      init = function(_context, settings)
        received = settings
      end,
    }
    local entries = plugin.compose {
      {
        id = 'settings',
        factory = function()
          made += 1
          return consumer.definition
        end,
        config = config,
      },
    }
    local running = if boundary == 'start' then management.start(entries) else management.start {}
    if boundary == 'add' then
      running.service:add(entries[1])
    end
    expect.equal(received, config)
    expect.equal(entry(running.service, 'settings').config, config)
    expect.falsy(table.isfrozen(config), 'a custom root remains caller-owned')
    config.marker = 'still mutable'
    local changed = {}
    running.service:configure('settings', changed)
    expect.equal(received, changed)
    expect.equal(entry(running.service, 'settings').previousConfig, config)
    expect.falsy(table.isfrozen(changed) or table.isfrozen(default))
    running.service:recover 'settings'
    expect.equal(received, config)
    expect.equal(received.marker, 'still mutable')
    expect.equal(made, 1)
    running.runtime:close()
  end)
end

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
  expect.equal(next(received), nil)
  running.service:disable 'provider'
  expect.equal(entry(running.service, 'dependent').state, 'inactive')
  running.service:enable 'provider'
  expect.equal(entry(running.service, 'dependent').state, 'active')
  expect.equal(next(received), nil)
  expect.equal(loads, 2)
  expect.equal(made, 1, 'provider recovery retains the source definition')
  running.runtime:close()
end)

local function invalidSources()
  return {
    { field = 'definition' },
    { value = false, field = 'definition' },
    { value = true, field = 'definition' },
    { value = 7, field = 'definition' },
    { value = 'invalid', field = 'definition' },
    { value = {}, field = 'name' },
    { value = setmetatable({}, {}), field = 'definition' },
    {
      value = { name = 'invalid', requires = {}, provides = {}, init = function() end, schema = false },
      field = 'schema',
    },
    {
      value = { name = 'invalid', requires = {}, provides = {}, init = function() end, resolve = false },
      field = 'resolve',
    },
  }
end

local function definitionProblem(ok, problem, field)
  expect.equal(ok, false)
  expect.equal(type(problem), 'table', 'invalid definitions use the structured management error')
  expect.equal(problem.code, 'definition')
  expect.equal(problem.entryId, 'invalid')
  expect.equal(problem.field, field)
  expect.truthy(table.isfrozen(problem))
end

test('invalid factory results produce structured errors before startup creates a native runtime', function()
  local runtime, registered, made, initialized = lunette.plugin.runtime, 0, 0, 0
  local valid = plugin.define {
    name = 'managed-valid-before-invalid',
    init = function()
      initialized += 1
    end,
  }
  lunette.plugin.runtime = function()
    registered += 1
    return runtime()
  end
  local verified, failure = pcall(function()
    for _, invalid in invalidSources() do
      local ok, problem = pcall(function()
        management.start {
          { id = 'valid', definition = valid },
          {
            id = 'invalid',
            factory = function()
              made += 1
              return invalid.value
            end,
          },
        }
      end)
      definitionProblem(ok, problem, invalid.field)
    end
    for _, invalid in invalidSources() do
      if type(invalid.value) == 'table' then
        local ok, problem = pcall(function()
          management.start { { id = 'invalid', definition = invalid.value } }
        end)
        definitionProblem(ok, problem, invalid.field)
      end
    end
    expect.equal(made, #invalidSources(), 'each invalid factory is called once')
    expect.equal(registered, 0, 'all definitions are checked before any native registration')
    expect.equal(initialized, 0)
    expect.equal(#testing.takeReports(), 0)
  end)
  lunette.plugin.runtime = runtime
  if not verified then
    error(failure, 0)
  end
end)

test('invalid factories and public definitions never enter the runtime or addition catalog', function()
  local running, made = management.start {}, 0
  for _, invalid in invalidSources() do
    local ok, problem = pcall(function()
      running.service:add {
        id = 'invalid',
        factory = function()
          made += 1
          return invalid.value
        end,
      }
    end)
    definitionProblem(ok, problem, invalid.field)
    expect.equal(#running.service:snapshot().instances, 1)
    expect.equal(entry(running.service, 'invalid'), nil)
    expect.equal(knownEntry(running.service, 'invalid'), nil)
    if type(invalid.value) == 'table' then
      ok, problem = pcall(function()
        running.service:add { id = 'invalid', definition = invalid.value }
      end)
      definitionProblem(ok, problem, invalid.field)
      expect.equal(#running.service:snapshot().instances, 1)
    end
  end
  expect.equal(made, #invalidSources())
  expect.equal(#testing.takeReports(), 0)
  running.runtime:close()
end)

test('errors raised by factories keep their original value at startup and addition', function()
  local failure, made = {}, 0
  local source = {
    id = 'raising',
    factory = function()
      made += 1
      error(failure, 0)
    end,
  }
  local ok, problem = pcall(function()
    management.start { source }
  end)
  expect.equal(ok, false)
  expect.equal(problem, failure)
  local running = management.start {}
  ok, problem = pcall(function()
    running.service:add(source)
  end)
  expect.equal(ok, false)
  expect.equal(problem, failure)
  expect.equal(made, 2)
  expect.equal(#running.service:snapshot().instances, 1)
  expect.equal(knownEntry(running.service, 'raising'), nil)
  running.runtime:close()
end)

for _, boundary in { 'start', 'add' } do
  test(boundary .. ' resolves a nested composed patch equally for known and factory destinations', function()
    for _, emptyMap in { false, true } do
      local handle, plain, seen, factories, initialized = {}, {}, {}, 0, 0
      handle.self = handle
      local opaque = schema.custom {
        runtimeType = 'table',
        validate = function(value)
          if value ~= handle and value ~= plain then
            error('managed nested patch identity changed', 0)
          end
          return value
        end,
      }
      local consumer = plugin.consumer {
        name = 'managed-nested-patch-' .. boundary,
        schema = schema.object {
          object = schema.default(schema.object {
            first = schema.default(schema.number())(1),
            second = schema.default(schema.number())(2),
            destination = schema.default(schema.number())(3),
          }) {},
          map = schema.default(schema.map(schema.string())) {},
          handle = schema.default(opaque)(handle),
          plain = schema.default(opaque)(plain),
        },
        init = function(_context, settings)
          initialized += 1
          seen[#seen + 1] = settings
        end,
      }
      local reused = plugin.compose {
        {
          id = 'reused',
          factory = function()
            error('the reused source factory must not run', 0)
          end,
          config = { object = { first = 8 }, map = { old = 'old' }, handle = handle, plain = plain },
        },
      }
      reused = plugin.compose(reused, {
        { id = 'reused', config = { object = { second = 9 }, map = if emptyMap then {} else { fresh = 'fresh' } } },
      })
      local entries = plugin.compose({
        { id = 'known', definition = consumer.definition, config = { object = { destination = 7 } } },
        {
          id = 'factory',
          factory = function()
            factories += 1
            expect.equal(initialized, 0, 'all sources resolve before startup activation')
            return consumer.definition
          end,
          config = { object = { destination = 7 } },
        },
      }, {
        { id = 'known', config = reused[1].config },
        { id = 'factory', config = reused[1].config },
      })
      expect.equal(factories, 0)
      expect.equal(initialized, 0)
      local running = if boundary == 'start' then management.start(entries) else management.start {}
      if boundary == 'add' then
        running.service:add(entries[2])
        running.service:add(entries[1])
      end
      expect.equal(factories, 1)
      expect.equal(initialized, 2)
      for _, id in { 'known', 'factory' } do
        local managed = entry(running.service, id)
        expect.equal(managed.state, 'active')
        expect.equal(managed.config.map.old, nil, 'a reused composed patch must retain map replacement')
        expect.equal(managed.config.map.fresh, if emptyMap then nil else 'fresh')
        expect.equal(managed.config.object.first, 8)
        expect.equal(managed.config.object.second, 9)
        expect.equal(managed.config.object.destination, 7)
        expect.equal(managed.config.handle, handle)
        expect.equal(managed.config.plain, plain)
        expect.truthy(table.isfrozen(managed.config.map) and table.isfrozen(managed.config.object))
      end
      for _, settings in seen do
        expect.equal(settings.map.old, nil)
        expect.equal(settings.map.fresh, if emptyMap then nil else 'fresh')
        expect.equal(settings.object.first, 8)
        expect.equal(settings.object.second, 9)
        expect.equal(settings.object.destination, 7)
        expect.equal(settings.handle, handle)
        expect.equal(settings.handle.self, handle)
        expect.equal(settings.plain, plain)
      end
      expect.falsy(table.isfrozen(handle) or table.isfrozen(plain))
      running.service:reload 'factory'
      expect.equal(factories, 1, 'reload uses the resolved definition')
      running.runtime:close()
    end
  end)
end

return test
