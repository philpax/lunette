-- Covers schema-backed configured definitions and their preflight metadata against the real runtime.

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
      names = schema.default(schema.map(schema.string())) { inherited = 'default' },
    }) { width = 4, colors = { 1, 0, 0 }, names = { inherited = 'default' } },
    note = schema.optional(schema.string()),
  }
end

local function activate(definition, config)
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, config or {})
  instance:enable()
  return runtime, instance
end

test('configured helpers reject unknown fields and false descriptors', function()
  local capability = plugin.capability { name = 'local/schema-malformed', schema = 1 }
  for _, make in
    {
      function(fields)
        fields.init = function() end
        return plugin.consumer(fields)
      end,
      function(fields)
        fields.capability = capability
        fields.build = function()
          return {}
        end
        return plugin.provider(fields)
      end,
    }
  do
    expect.raises(function()
      make { name = 'schema-unknown', schema = descriptor(), defualts = {} }
    end, 'unknown field defualts')
    for _, invalid in
      { false, 42, {}, {
        parse = function()
          return {}
        end,
      } }
    do
      expect.raises(function()
        make { name = 'schema-invalid', schema = invalid }
      end, 'schema')
    end
    expect.raises(function()
      make { name = 'schema-required', schema = schema.object { required = schema.string() } }
    end, 'required')
  end
end)

test('define binds nested defaults for preflight and activation without changing the original', function()
  local observed = {}
  local made = plugin.consumer {
    name = 'schema-consumer',
    schema = descriptor(),
    init = function(_context, settings)
      observed[#observed + 1] = settings
    end,
  }
  local fields = { name = 'schema-renamed', count = 7, style = { width = 8, colors = { 0, 1 } } }
  local bound = made.define(fields)
  fields.style.colors[2] = 9
  expect.equal(fields.name, 'schema-renamed', 'the fields remain caller-owned')
  expect.equal(bound.name, 'schema-renamed')
  local preflight = bound.resolve { style = { colors = {}, names = { fresh = 'new' } }, note = 'present' }
  expect.equal(preflight.count, 7)
  expect.equal(preflight.style.width, 8)
  expect.equal(#preflight.style.colors, 0)
  expect.equal(preflight.style.names.inherited, nil, 'maps replace instead of merging')
  expect.equal(preflight.style.names.fresh, 'new')
  expect.equal(preflight.note, 'present')
  expect.equal(bound.resolve(nil).style.colors[2], 1, 'defined defaults were copied')
  expect.equal(made.definition.resolve({}).count, 2, 'the default definition remains unchanged')
  expect.equal(made.define({}).name, 'schema-consumer')
  local runtime = plugin.runtime()
  runtime:use(bound, { style = { colors = {}, names = {} } }):enable()
  runtime:use(made.definition, {}):enable()
  expect.equal(observed[1].count, 7)
  expect.equal(observed[1].style.width, 8)
  expect.equal(#observed[1].style.colors, 0)
  expect.equal(next(observed[1].style.names), nil)
  expect.equal(observed[2].count, 2)
  expect.truthy(table.isfrozen(observed[1]) and table.isfrozen(observed[1].style))
  expect.equal(observed[1].note, nil)
  runtime:close()
end)

test('definitions expose schema metadata with their bound default', function()
  local source = descriptor()
  local made = plugin.consumer { name = 'schema-metadata', schema = source, init = function() end }
  local bound = made.define { count = 9, style = { width = 10 } }
  local metadata = bound.schema
  expect.equal(metadata.kind, 'default')
  expect.equal(metadata.child, source.inspect(), 'metadata retains the parser descriptor')
  expect.equal(metadata.value.count, 9)
  expect.equal(metadata.value.style.width, 10)
  expect.equal(made.definition.schema.value.count, 2)
  local plain = plugin.consumer { name = 'schema-none', init = function() end }
  expect.equal(plain.definition.schema.child.kind, 'object', 'a consumer without a schema takes an empty object')
  expect.raises(function()
    plain.definition.resolve { count = 4 }
  end, 'plugin schema%-none: option count is not a declared field')
  local raw = plugin.define { name = 'schema-raw', init = function() end }
  expect.equal(raw.schema, nil)
  expect.equal(raw.resolve, nil, 'low-level definitions do not change their configuration contract')
  expect.raises(function()
    plugin.define { name = 'schema-raw-invalid', schema = source, init = function() end }
  end, 'unknown field schema')
end)

test('schema refinements run before definition build and activation', function()
  local built = 0
  local capability = plugin.capability { name = 'local/schema-provider', schema = 1 }
  local refined = schema.refine(descriptor())(function(settings)
    if settings.count > settings.style.width then
      error('count exceeds width', 0)
    end
  end)
  local made = plugin.provider {
    name = 'schema-provider',
    capability = capability,
    schema = refined,
    build = function(_context, settings)
      built += 1
      return settings
    end,
  }
  expect.equal(made.build(nil, {}).count, 2)
  expect.equal(made.build(nil, { count = 3 }).count, 3)
  expect.equal(built, 2)
  for _, config in { { count = 5 }, { count = 'wrong' }, { unknown = true } } do
    expect.raises(function()
      made.build(nil, config)
    end, 'schema%-provider')
    expect.raises(function()
      made.define(config)
    end, 'schema%-provider')
    expect.raises(function()
      made.definition.resolve(config)
    end, 'schema%-provider')
    local runtime, instance = activate(made.definition, config)
    expect.equal(instance:state(), 'failed')
    expect.truthy(instance:diagnostic():find('schema-provider', 1, true))
    expect.equal(#testing.takeReports(), 1, 'the failed configuration is reported once')
    runtime:close()
  end
  expect.equal(built, 2, 'invalid settings never reach the builder')
  local bound = made.define { name = 'schema-bound-provider', count = 6, style = { width = 7 } }
  local runtime, instance = activate(bound, { style = { width = 8 } })
  expect.equal(instance:state(), 'active', tostring(instance:diagnostic()))
  expect.equal(built, 3)
  runtime:close()
  local initialized = 0
  expect.raises(function()
    plugin.consumer {
      name = 'schema-invalid-base',
      schema = schema.refine(descriptor())(function()
        error('invalid base', 0)
      end),
      init = function()
        initialized += 1
      end,
    }
  end, 'invalid base')
  expect.equal(initialized, 0, 'invalid defaults fail at construction')
end)

test('callbacks custom values and native vectors retain identity through bound resolution', function()
  local callback = function(value)
    return value + 1
  end
  local handle = setmetatable({ marker = 'custom' }, {})
  local position = vector.pack(1, 2, 3)
  local custom = schema.custom {
    runtimeType = 'table',
    validate = function(value)
      if value ~= handle then
        error('wrong handle', 0)
      end
      return value
    end,
  }
  local received
  local made = plugin.consumer {
    name = 'schema-native-values',
    schema = schema.object {
      callback = schema.default(schema.callback(callback))(callback),
      handle = schema.default(custom)(handle),
      position = schema.default(schema.vector())(position),
    },
    init = function(_context, settings)
      received = settings
    end,
  }
  local definition = made.define { name = 'schema-native-bound' }
  local settings = definition.resolve {}
  expect.equal(settings.callback, callback)
  expect.equal(settings.handle, handle)
  expect.equal(settings.position, position)
  expect.equal(definition.schema.value.handle, handle)
  expect.falsy(table.isfrozen(handle), 'custom handles stay caller-owned')
  local runtime, instance = activate(definition)
  expect.equal(instance:state(), 'active', tostring(instance:diagnostic()))
  expect.equal(received.handle, handle)
  expect.equal(received.callback(2), 3)
  expect.equal(received.position, position)
  runtime:close()
end)

test('invalid reloads fail before init and a later valid reload uses bound defaults', function()
  local observed = {}
  local made = plugin.consumer {
    name = 'schema-reload',
    schema = descriptor(),
    init = function(_context, settings)
      observed[#observed + 1] = settings
    end,
  }
  local bound = made.define { count = 7, style = { width = 8 } }
  local runtime, instance = activate(bound, { style = { width = 9 } })
  expect.equal(instance:state(), 'active', tostring(instance:diagnostic()))
  instance:reload { count = false }
  expect.equal(instance:state(), 'failed')
  expect.equal(#observed, 1, 'a failed reload does not initialize')
  expect.equal(#testing.takeReports(), 1)
  instance:reload { style = { width = 10 } }
  expect.equal(instance:state(), 'active', tostring(instance:diagnostic()))
  expect.equal(#observed, 2)
  expect.equal(observed[2].count, 7, 'reload retains the definition defaults')
  expect.equal(observed[2].style.width, 10)
  expect.equal(observed[1].style.width, 9, 'previous resolved settings remain unchanged')
  runtime:close()
end)

test('schema-backed initializers retain the no-return contract', function()
  local made = plugin.consumer {
    name = 'schema-return',
    schema = descriptor(),
    init = function()
      return nil
    end,
  }
  local runtime, instance = activate(made.definition)
  expect.equal(instance:state(), 'failed')
  local reports = testing.takeReports()
  expect.equal(#reports, 1)
  expect.truthy(reports[1]:find('initializer must return nothing', 1, true), reports[1])
  runtime:close()
end)

test('a definition factory retains state across its activations but not across runtimes', function()
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

test('provider define and unpublished build share the consumer configuration rules', function()
  local capability = plugin.capability { name = 'local/configured-parity', schema = 1 }
  local built, consumerSettings, service = 0, nil, nil
  local source = plugin.provider {
    name = 'configured-parity-provider',
    capability = capability,
    schema = descriptor(),
    build = function(_context, settings)
      built += 1
      return { settings = settings }
    end,
  }
  local sink = plugin.consumer {
    name = 'configured-parity-consumer',
    schema = descriptor(),
    init = function(_context, settings)
      consumerSettings = settings
    end,
  }
  local over = { count = 4, style = { width = 8 } }
  local provided = source.define(over)
  local consumed = sink.define(over)
  expect.equal(built, 0, 'provider construction does not build a service')
  local runtime = plugin.runtime()
  local config = { count = 6 }
  runtime:use(provided, config):enable()
  runtime:use(consumed, config):enable()
  runtime
    :use(
      plugin.define {
        name = 'configured-parity-observer',
        requires = { source = capability },
        init = function(context)
          service = context:require(capability)
          expect.raises(function()
            source.build(context, { style = { depth = 1 } })
          end, 'option style.depth is not a declared field')
          local unpublished = source.build(context)
          expect.equal(unpublished.settings.count, 2, 'build uses the original provider defaults')
          expect.truthy(unpublished ~= service, 'build returns an unpublished service')
          expect.equal(context:require(capability).settings.count, 6, 'build does not replace the published service')
        end,
      },
      {}
    )
    :enable()
  expect.equal(service.settings.count, consumerSettings.count, 'the runtime override agrees')
  expect.equal(service.settings.style.width, consumerSettings.style.width, 'the defined nested default agrees')
  expect.equal(built, 2, 'only activation and explicit build construct services')
  runtime:close()
end)

return test
