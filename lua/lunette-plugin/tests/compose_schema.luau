-- Covers descriptor-directed composition and opaque configuration identity against the real runtime.

local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local compose = require '@lunette-plugin/compose'
local schema = require '@lunette-plugin/schema'

local test = testing.suite()

local function source(definition, factory)
  return if factory then { id = 'configured', factory = factory } else { id = 'configured', definition = definition }
end

for _, factorySource in { false, true } do
  local label = if factorySource then 'factory' else 'definition'

  test(label .. ' composition preserves custom tables metatables and callbacks', function()
    local plain = { marker = 'plain' }
    local backed = setmetatable({ marker = 'backed' }, {})
    local callback = function(value)
      return value + 1
    end
    local seen, made = {}, 0
    local opaque = schema.custom {
      runtimeType = 'table',
      validate = function(value)
        if value ~= plain and value ~= backed then
          error('custom identity changed', 0)
        end
        return value
      end,
    }
    local consumer = plugin.consumer {
      name = 'compose-opaque-' .. label,
      schema = schema.object {
        plain = schema.default(opaque)(plain),
        backed = schema.default(opaque)(backed),
        callback = schema.default(schema.callback(callback))(callback),
        list = schema.default(schema.array(opaque)) { plain },
        map = schema.default(schema.map(opaque)) { kept = backed },
      },
      init = function(_context, settings)
        seen[#seen + 1] = settings
      end,
    }
    local factory = if factorySource
      then function()
        made += 1
        return consumer.definition
      end
      else nil
    local entry = source(consumer.definition, factory)
    entry.config = { plain = plain, backed = backed, callback = callback, list = { backed }, map = { fresh = plain } }
    local entries = plugin.compose { entry }
    entries = plugin.compose(entries, {
      { id = 'configured', config = { plain = backed, backed = plain, list = { plain }, map = { replaced = backed } } },
    })
    entries = plugin.compose(entries)
    expect.equal(made, 0, 'composition does not call the factory')
    local first, second = plugin.start(entries), plugin.start(entries)
    expect.equal(first.instances.configured:state(), 'active', tostring(first.instances.configured:diagnostic()))
    expect.equal(second.instances.configured:state(), 'active', tostring(second.instances.configured:diagnostic()))
    expect.equal(made, if factorySource then 2 else 0, 'one factory call per start')
    first.instances.configured:disable()
    first.instances.configured:enable()
    expect.equal(made, if factorySource then 2 else 0, 'reactivation retains the definition')
    expect.equal(#seen, 3)
    for _, settings in seen do
      expect.equal(settings.plain, backed)
      expect.equal(settings.backed, plain)
      expect.equal(settings.callback, callback)
      expect.equal(settings.callback(2), 3)
      expect.equal(settings.list[1], plain)
      expect.equal(settings.map.replaced, backed)
      expect.equal(settings.map.fresh, nil, 'a map patch replaces the entry map')
      expect.truthy(table.isfrozen(settings) and table.isfrozen(settings.list), 'structural settings are frozen')
    end
    expect.falsy(table.isfrozen(plain) or table.isfrozen(backed), 'custom tables stay caller-owned')
    expect.equal(plain.marker, 'plain', 'composition does not change custom values')
    first.runtime:close()
    second.runtime:close()
  end)

  test(label .. ' composition accepts cyclic custom values without copying them', function()
    local base, replacement = {}, {}
    base.self, replacement.self = base, replacement
    local seen
    local opaque = schema.custom {
      runtimeType = 'table',
      validate = function(value)
        if value ~= base and value ~= replacement then
          error('cyclic identity changed', 0)
        end
        return value
      end,
    }
    local consumer = plugin.consumer {
      name = 'compose-cycle-' .. label,
      schema = schema.object { handle = schema.default(opaque)(base) },
      init = function(_context, settings)
        seen = settings.handle
      end,
    }
    local entry = source(
      consumer.definition,
      if factorySource
        then function()
          return consumer.definition
        end
        else nil
    )
    entry.config = { handle = base }
    local entries = plugin.compose { entry }
    entries = plugin.compose(entries, { { id = 'configured', config = { handle = replacement } } })
    local running = plugin.start(entries)
    expect.equal(running.instances.configured:state(), 'active', tostring(running.instances.configured:diagnostic()))
    expect.equal(seen, replacement)
    expect.equal(seen.self, replacement)
    expect.falsy(table.isfrozen(base) or table.isfrozen(replacement))
    running.runtime:close()
  end)

  test(label .. ' composition replaces collections and merges declared objects including empty patches', function()
    local seen, made = {}, 0
    local consumer = plugin.consumer {
      name = 'compose-collections-' .. label,
      schema = schema.refine(schema.object {
        style = schema.default(schema.object {
          width = schema.default(schema.number())(1),
          height = schema.default(schema.number())(2),
          array = schema.default(schema.array(schema.number())) { 1, 2 },
          map = schema.default(schema.map(schema.string())) { default = 'default' },
          choice = schema.default(
            schema.union(
              schema.object { left = schema.string(), right = schema.optional(schema.string()) },
              schema.string()
            )
          ) { left = 'default', right = 'default' },
        }) {},
      })(function() end),
      init = function(_context, settings)
        seen[#seen + 1] = settings
      end,
    }
    local factory = if factorySource
      then function()
        made += 1
        return consumer.define { style = { height = 9 } }
      end
      else nil
    local entry = source(consumer.define { style = { height = 9 } }, factory)
    entry.config = {
      style = { width = 4, array = { 3, 4 }, map = { old = 'old' }, choice = { left = 'entry', right = 'entry' } },
    }
    local entries = plugin.compose { entry }
    entries = plugin.compose(entries, {
      { id = 'configured', config = { style = { width = 5, map = { fresh = 'fresh' }, choice = { left = 'patch' } } } },
    })
    local first = plugin.start(entries)
    expect.equal(first.instances.configured:state(), 'active', tostring(first.instances.configured:diagnostic()))
    expect.equal(seen[1].style.width, 5)
    expect.equal(seen[1].style.height, 9, 'bound defaults survive entry and object patches')
    expect.equal(seen[1].style.array[2], 4, 'an omitted collection retains the entry override')
    expect.equal(seen[1].style.map.old, nil, 'a map replaces rather than merging string keys')
    expect.equal(seen[1].style.map.fresh, 'fresh')
    expect.equal(seen[1].style.choice.right, nil, 'a union replaces even when its chosen alternative is an object')
    entries = plugin.compose(entries, { { id = 'configured', config = { style = {} } } })
    local second = plugin.start(entries)
    expect.equal(seen[2].style.width, 5, 'an empty object patch retains entry options')
    entries = plugin.compose(entries, { { id = 'configured', config = { style = { array = {}, map = {} } } } })
    local third = plugin.start(entries)
    expect.equal(#seen[3].style.array, 0, 'an empty array clears the entry override and defaults')
    expect.equal(next(seen[3].style.map), nil, 'an empty map clears the entry override and defaults')
    expect.equal(seen[3].style.width, 5, 'object siblings remain')
    expect.equal(made, if factorySource then 3 else 0, 'each start calls the factory once')
    first.runtime:close()
    second.runtime:close()
    third.runtime:close()
  end)

  test(label .. ' composition snapshots structural options and defers validation to its instance', function()
    local seen, validated = nil, 0
    local consumer = plugin.consumer {
      name = 'compose-validation-' .. label,
      schema = schema.object {
        style = schema.default(schema.object { width = schema.default(schema.number())(1) }) {},
        values = schema.default(schema.array(schema.number())) { 1 },
      },
      validate = function()
        validated += 1
      end,
      init = function(_context, settings)
        seen = settings
      end,
    }
    local entry = source(
      consumer.definition,
      if factorySource
        then function()
          return consumer.definition
        end
        else nil
    )
    entry.config = { style = { width = 4 }, values = { 2 } }
    local patch = { id = 'configured', config = { style = { width = 5 } } }
    local entries = plugin.compose({ entry }, { patch })
    entry.config.values[1], patch.config.style.width = 99, 99
    expect.equal(validated, 1, 'composition invokes no configured validator')
    local running = plugin.start(entries)
    expect.equal(seen.style.width, 5, 'patch structural values were snapshotted')
    expect.equal(seen.values[1], 2, 'entry structural values were snapshotted')
    running.runtime:close()
    local invalid = plugin.compose(entries, { { id = 'configured', config = { style = { width = 'wrong' } } } })
    local healthy = plugin.define { name = 'compose-healthy-' .. label, init = function() end }
    invalid = plugin.compose(invalid, { { insert = { id = 'healthy', definition = healthy } } })
    local failed = plugin.start(invalid)
    expect.equal(failed.instances.configured:state(), 'failed')
    expect.equal(failed.instances.healthy:state(), 'active', 'a configuration failure does not stop later entries')
    expect.truthy(failed.instances.configured:diagnostic():find('width', 1, true))
    expect.equal(#testing.takeReports(), 1)
    failed.runtime:close()
  end)
end

test('raw and legacy factory entries retain record merging and detached frozen configuration', function()
  for _, legacy in { false, true } do
    local seen
    local definition = if legacy
      then plugin.consumer({
        name = 'compose-legacy-factory',
        defaults = { style = { width = 1, height = 2 }, names = { old = 'old', fresh = 'default' } },
        init = function(_context, settings)
          seen = settings
        end,
      }).definition
      else plugin.define {
        name = 'compose-raw-factory',
        init = function(_context, config)
          seen = config
        end,
      }
    local config = { style = { width = 4, height = 3 }, names = { old = 'entry' } }
    local patch = { id = 'configured', config = { style = { width = 5 }, names = { fresh = 'patch' } } }
    local entries = plugin.compose({
      {
        id = 'configured',
        factory = function()
          return definition
        end,
        config = config,
      },
    }, { patch })
    config.style.height, patch.config.style.width = 99, 99
    expect.truthy(table.isfrozen(entries[1].config.style))
    local running = plugin.start(entries)
    expect.equal(running.instances.configured:state(), 'active', tostring(running.instances.configured:diagnostic()))
    expect.equal(seen.style.width, 5)
    expect.equal(seen.style.height, 3)
    expect.equal(seen.names.old, 'entry')
    expect.equal(seen.names.fresh, 'patch')
    running.runtime:close()
  end
end)

test('entry resolution shares deferred factory semantics with independent runtime owners', function()
  local handle, seen, made = {}, nil, 0
  handle.self = handle
  local consumer = plugin.consumer {
    name = 'compose-independent-owner',
    schema = schema.object {
      handle = schema.default(schema.custom {
        runtimeType = 'table',
        validate = function(value)
          if value ~= handle then
            error('identity changed', 0)
          end
          return value
        end,
      })(handle),
      map = schema.default(schema.map(schema.string())) {},
    },
    init = function(_context, settings)
      seen = settings
    end,
  }
  local factory = function()
    made += 1
    return consumer.definition
  end
  local entries = plugin.compose(
    { { id = 'configured', factory = factory, config = { handle = handle, map = { old = 'old' } } } },
    {
      { id = 'configured', config = { map = { fresh = 'fresh' } } },
    }
  )
  local checked = compose.apply { { id = entries[1].id, factory = entries[1].factory } }
  local rebuilt = { id = checked[1].id, factory = checked[1].factory, config = entries[1].config }
  expect.equal(made, 0, 'entry validation and rebuilding do not invoke the factory')
  local resolved = compose.resolveEntry(rebuilt)
  expect.equal(made, 1)
  expect.equal(resolved.definition, consumer.definition)
  expect.equal(resolved.config.handle, handle)
  expect.equal(resolved.config.map.old, nil)
  expect.equal(resolved.config.map.fresh, 'fresh')
  expect.truthy(table.isfrozen(resolved) and table.isfrozen(resolved.config.map))
  local runtime = plugin.runtime()
  local instance = runtime:use(resolved.definition, resolved.config)
  instance:enable()
  expect.equal(instance:state(), 'active', tostring(instance:diagnostic()))
  expect.equal(seen.handle, handle)
  instance:disable()
  instance:enable()
  expect.equal(made, 1, 'activation never reevaluates the factory')
  runtime:close()
end)

test('factory union values preserve nested custom identities without merging alternatives', function()
  local handle, received = {}, nil
  local opaque = schema.custom {
    runtimeType = 'table',
    validate = function(value)
      if value ~= handle then
        error('union identity changed', 0)
      end
      return value
    end,
  }
  local consumer = plugin.consumer {
    name = 'compose-union-identity',
    schema = schema.object {
      choice = schema.default(
        schema.union(schema.object { handle = opaque, note = schema.optional(schema.string()) }, schema.string())
      ) { handle = handle, note = 'default' },
    },
    init = function(_context, settings)
      received = settings.choice
    end,
  }
  local entries = plugin.compose {
    {
      id = 'configured',
      factory = function()
        return consumer.definition
      end,
      config = { choice = { handle = handle, note = 'entry' } },
    },
  }
  entries = plugin.compose(entries, { { id = 'configured', config = { choice = { handle = handle } } } })
  local running = plugin.start(entries)
  expect.equal(running.instances.configured:state(), 'active', tostring(running.instances.configured:diagnostic()))
  expect.equal(received.handle, handle)
  expect.equal(received.note, nil)
  expect.falsy(table.isfrozen(handle))
  running.runtime:close()
end)

test('replacing a factory with a known definition resolves existing deferred layers without running it', function()
  local made, received = 0, nil
  local consumer = plugin.consumer {
    name = 'compose-replaced-source',
    schema = schema.object {
      object = schema.default(schema.object {
        first = schema.default(schema.number())(1),
        second = schema.default(schema.number())(2),
      }) {},
      map = schema.default(schema.map(schema.string())) {},
    },
    init = function(_context, settings)
      received = settings
    end,
  }
  local entries = plugin.compose {
    {
      id = 'configured',
      factory = function()
        made += 1
        return consumer.definition
      end,
      config = { object = { first = 3 }, map = { old = 'old' } },
    },
  }
  entries = plugin.compose(entries, { { id = 'configured', config = { map = { fresh = 'fresh' } } } })
  entries =
    plugin.compose(entries, { { id = 'configured', definition = consumer.definition, config = { object = {} } } })
  expect.equal(made, 0)
  expect.equal(entries[1].config.map.old, nil)
  local running = plugin.start(entries)
  expect.equal(running.instances.configured:state(), 'active', tostring(running.instances.configured:diagnostic()))
  expect.equal(received.object.first, 3)
  expect.equal(received.object.second, 2)
  expect.equal(received.map.fresh, 'fresh')
  expect.equal(made, 0)
  running.runtime:close()
end)

test('a root custom configuration stays opaque and caller-owned', function()
  local default, config, received = {}, {}, nil
  local consumer = plugin.consumer {
    name = 'compose-root-custom',
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
      id = 'configured',
      factory = function()
        return consumer.definition
      end,
      config = config,
    },
  }
  local resolved = compose.resolveEntry(entries[1])
  expect.equal(resolved.config, config)
  expect.falsy(table.isfrozen(config))
  local running = plugin.start(entries)
  expect.equal(running.instances.configured:state(), 'active', tostring(running.instances.configured:diagnostic()))
  expect.equal(received, config)
  expect.falsy(table.isfrozen(config))
  running.runtime:close()
end)

test('nested composed patches resolve the same map objects and custom identities for either source', function()
  for _, emptyMap in { false, true } do
    for depth = 1, 3 do
      local old, replacement, plain = {}, {}, { marker = 'plain' }
      old.self, replacement.self = old, replacement
      local initialized, reusedFactories, destinationFactories, seen = 0, 0, 0, {}
      local opaque = schema.custom {
        runtimeType = 'table',
        validate = function(value)
          if value ~= old and value ~= replacement and value ~= plain then
            error('nested patch custom identity changed', 0)
          end
          return value
        end,
      }
      local consumer = plugin.consumer {
        name = 'compose-nested-patch',
        schema = schema.object {
          object = schema.default(schema.object {
            first = schema.default(schema.number())(1),
            second = schema.default(schema.number())(2),
            destination = schema.default(schema.number())(3),
          }) {},
          map = schema.default(schema.map(schema.string())) {},
          handle = schema.default(opaque)(old),
          plain = schema.default(opaque)(plain),
        },
        init = function(_context, settings)
          initialized += 1
          seen[#seen + 1] = settings
        end,
      }
      local function reusable(config)
        return plugin.compose {
          {
            id = 'reusable',
            factory = function()
              reusedFactories += 1
              return consumer.definition
            end,
            config = config,
          },
        }
      end
      local finalMap = if emptyMap then {} else { fresh = 'fresh' }
      local nested = reusable { object = { first = 8 }, map = { old = 'old' }, handle = old, plain = plain }
      nested = plugin.compose(nested, {
        { id = 'reusable', config = { object = { second = 9 }, map = finalMap, handle = replacement } },
      })
      for _ = 2, depth do
        nested = plugin.compose(reusable { map = { intermediate = 'intermediate' } }, {
          { id = 'reusable', config = nested[1].config },
        })
        nested = plugin.compose(nested)
      end
      local destination = { object = { destination = 7 }, map = { destination = 'destination' } }
      local entries = plugin.compose({
        { id = 'known', definition = consumer.definition, config = destination },
        {
          id = 'factory',
          factory = function()
            destinationFactories += 1
            return consumer.definition
          end,
          config = destination,
        },
      }, {
        { id = 'known', config = nested[1].config },
        { id = 'factory', config = nested[1].config },
      })
      entries = plugin.compose(entries)
      expect.equal(reusedFactories, 0, 'reusing configuration never runs its source factory')
      expect.equal(destinationFactories, 0)
      expect.equal(initialized, 0)
      local known, deferred = compose.resolveEntry(entries[1]), compose.resolveEntry(entries[2])
      expect.equal(destinationFactories, 1)
      expect.equal(initialized, 0, 'canonical replay does not initialize a plugin')
      for _, resolved in { known, deferred } do
        expect.equal(resolved.config.map.old, nil, 'the nested map patch replaces its prior map')
        expect.equal(resolved.config.map.intermediate, nil)
        expect.equal(resolved.config.map.destination, nil)
        expect.equal(resolved.config.map.fresh, if emptyMap then nil else 'fresh')
        expect.equal(resolved.config.object.first, 8)
        expect.equal(resolved.config.object.second, 9)
        expect.equal(resolved.config.object.destination, 7, 'the nested object merges with the destination')
        expect.equal(resolved.config.handle, replacement)
        expect.equal(resolved.config.handle.self, replacement)
        expect.equal(resolved.config.plain, plain)
      end
      local running = plugin.start(entries)
      expect.equal(running.instances.known:state(), 'active')
      expect.equal(running.instances.factory:state(), 'active')
      expect.equal(initialized, 2)
      expect.equal(destinationFactories, 2, 'one factory call for resolution and one for the separate start')
      expect.equal(reusedFactories, 0)
      for _, settings in seen do
        expect.equal(settings.map.old, nil)
        expect.equal(settings.map.intermediate, nil)
        expect.equal(settings.map.destination, nil)
        expect.equal(settings.map.fresh, if emptyMap then nil else 'fresh')
        expect.equal(settings.object.first, 8)
        expect.equal(settings.object.second, 9)
        expect.equal(settings.object.destination, 7)
        expect.equal(settings.handle, replacement)
        expect.equal(settings.plain, plain)
      end
      expect.falsy(table.isfrozen(replacement) or table.isfrozen(plain))
      expect.equal(destination.map.destination, 'destination', 'the destination input is unchanged')
      running.runtime:close()
    end
  end
end)

return test
