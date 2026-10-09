-- Covers plugin.consumer and plugin.provider: configuration schemas, bound defaults, and unpublished builds.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'

local test = testing.suite()

local function descriptor()
  return schema.object {
    count = schema.default(schema.number { minimum = 1, integer = true })(2),
    style = schema.default(schema.object {
      width = schema.default(schema.number { minimum = 0 })(3),
      colors = schema.default(schema.array(schema.number())) { 1, 1, 1 },
    }) { width = 4, colors = { 1, 0, 0 } },
  }
end

local function activate(definition, config)
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, config or {})
  instance:enable()
  return runtime, instance
end

test('a configured definition rejects an unknown field and a schema with a required field', function()
  expect.raises(function()
    plugin.consumer { name = 'schema-unknown', schema = descriptor(), defualts = {}, init = function() end }
  end, 'unknown field defualts')
  expect.raises(function()
    plugin.consumer {
      name = 'schema-required',
      schema = schema.object { required = schema.string() },
      init = function() end,
    }
  end, 'required')
end)

test('define binds nested defaults that activation merges with its configuration', function()
  local observed = {}
  local made = plugin.consumer {
    name = 'schema-consumer',
    schema = descriptor(),
    init = function(_context, settings)
      observed[#observed + 1] = settings
    end,
  }
  local bound = made.define { name = 'schema-renamed', count = 7, style = { width = 8 } }
  expect.equal(bound.name, 'schema-renamed', 'the bound name')
  expect.equal(bound.schema.value.count, 7, 'the schema metadata carries the bound default')
  expect.equal(made.definition.resolve({}).count, 2, 'the original definition is unchanged')
  local runtime = plugin.runtime()
  runtime:use(bound, { style = { colors = {} } }):enable()
  runtime:use(made.definition, {}):enable()
  expect.equal(observed[1].count, 7, 'the bound default')
  expect.equal(observed[1].style.width, 8, 'the bound nested default')
  expect.equal(#observed[1].style.colors, 0, 'a configured list replaces its default')
  expect.equal(observed[2].count, 2, 'the schema default')
  expect.truthy(table.isfrozen(observed[1]) and table.isfrozen(observed[1].style), 'the settings are frozen')
  runtime:close()
  local raw = plugin.define { name = 'schema-raw', init = function() end }
  expect.equal(raw.schema, nil, 'a low-level definition has no schema')
  local plain = plugin.consumer { name = 'schema-none', init = function() end }
  expect.raises(function()
    plain.definition.resolve { count = 4 }
  end, 'plugin schema%-none: option count is not a declared field')
end)

test('an invalid configuration never reaches the builder and fails the activation that carries it', function()
  local built = 0
  local made = plugin.provider {
    name = 'schema-provider',
    capability = plugin.capability { name = 'local/schema-provider', schema = 1 },
    schema = schema.refine(descriptor())(function(settings)
      if settings.count > settings.style.width then
        error('count exceeds width', 0)
      end
    end),
    build = function(_context, settings)
      built += 1
      return settings
    end,
  }
  for _, config in { { count = 5 }, { count = 'wrong' } } do
    expect.raises(function()
      made.define(config)
    end, 'schema%-provider')
    local runtime, instance = activate(made.definition, config)
    expect.equal(instance:state(), 'failed', 'the misconfigured provider')
    expect.truthy(tostring(instance:diagnostic()):find('schema-provider', 1, true), 'the diagnostic')
    expect.equal(#testing.takeReports(), 1, 'the failed configuration is reported once')
    runtime:close()
  end
  expect.equal(built, 0, 'invalid settings never reach the builder')
  expect.raises(function()
    plugin.consumer {
      name = 'schema-invalid-base',
      schema = schema.refine(descriptor())(function()
        error('invalid base', 0)
      end),
      init = function() end,
    }
  end, 'invalid base')
end)

test('callbacks, custom values, and vectors keep their identity through resolution', function()
  local callback = function(value)
    return value + 1
  end
  local handle = setmetatable({ marker = 'custom' }, {})
  local position = vector.pack(1, 2, 3)
  local received
  local made = plugin.consumer {
    name = 'schema-native-values',
    schema = schema.object {
      callback = schema.default(schema.callback(callback))(callback),
      handle = schema.default(schema.custom {
        runtimeType = 'table',
        validate = function(value)
          return value
        end,
      })(handle),
      position = schema.default(schema.vector())(position),
    },
    init = function(_context, settings)
      received = settings
    end,
  }
  local runtime = activate(made.define { name = 'schema-native-bound' })
  expect.equal(received.callback, callback, 'the callback')
  expect.equal(received.handle, handle, 'the custom value')
  expect.equal(received.position, position, 'the vector')
  expect.falsy(table.isfrozen(handle), 'a custom value stays caller-owned')
  runtime:close()
end)

test('an invalid reload fails before init, and a later valid reload uses the bound defaults', function()
  local observed = {}
  local made = plugin.consumer {
    name = 'schema-reload',
    schema = descriptor(),
    init = function(_context, settings)
      observed[#observed + 1] = settings
    end,
  }
  local runtime, instance = activate(made.define { count = 7, style = { width = 8 } }, { style = { width = 9 } })
  instance:reload { count = false }
  expect.equal(instance:state(), 'failed', 'the invalid reload')
  expect.equal(#observed, 1, 'a failed reload does not initialize')
  expect.equal(#testing.takeReports(), 1, 'the invalid reload is reported')
  instance:reload { style = { width = 10 } }
  expect.equal(instance:state(), 'active', tostring(instance:diagnostic()))
  expect.equal(observed[2].count, 7, 'the reload keeps the bound default')
  expect.equal(observed[2].style.width, 10, 'the reloaded configuration')
  runtime:close()
end)

test('a definition factory keeps state across its activations but not across runtimes', function()
  local observed = {}
  local function factory()
    local count = 0
    return plugin.consumer({
      name = 'configured-factory',
      init = function()
        count += 1
        observed[#observed + 1] = count
      end,
    }).definition
  end
  local entries = { { id = 'configured-factory', factory = factory } }
  local first = testing.start(entries)
  first.instances['configured-factory']:disable()
  first.instances['configured-factory']:enable()
  first:close()
  testing.start(entries)
  expect.equal(table.concat(observed, ','), '1,2,1', 'factory state is isolated per runtime')
end)

test('a provider build answers an unpublished service with the original defaults', function()
  local capability = plugin.capability { name = 'local/configured-build', schema = 1 }
  local source = plugin.provider {
    name = 'configured-build-provider',
    capability = capability,
    schema = descriptor(),
    build = function(_context, settings)
      return { settings = settings }
    end,
  }
  local runtime = plugin.runtime()
  runtime:use(source.define { count = 4 }, { count = 6 }):enable()
  runtime
    :use(
      plugin.define {
        name = 'configured-build-observer',
        requires = { source = capability },
        init = function(context)
          local unpublished = source.build(context)
          expect.equal(unpublished.settings.count, 2, 'build uses the original provider defaults')
          expect.equal(context:require(capability).settings.count, 6, 'the published service is unchanged')
          expect.raises(function()
            source.build(context, { style = { depth = 1 } })
          end, 'option style.depth is not a declared field')
        end,
      },
      {}
    )
    :enable()
  runtime:close()
end)

return test
