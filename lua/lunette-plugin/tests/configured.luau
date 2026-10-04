-- Covers the configured consumer and provider authoring surfaces against the real plugin runtime.

local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'

local test = testing.suite()

local function validate(settings, name)
  if settings.mode ~= 'quiet' and settings.mode ~= 'visible' then
    error('plugin ' .. name .. ': option mode is quiet or visible', 0)
  end
end

local function consumer(init, defaults)
  return plugin.consumer {
    name = 'configured-consumer',
    defaults = defaults or { count = 1, style = { width = 2, color = { 1, 1, 1 } }, mode = 'quiet' },
    validate = validate,
    init = init or function() end,
  }
end

local function activate(definition, config)
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, config or {})
  instance:enable()
  return runtime, instance
end

test('define sets defaults, and runtime overrides merge over them without changing other definitions', function()
  local observed = {}
  local made = consumer(function(_context, settings)
    observed[#observed + 1] = settings
  end)
  local fields = { name = 'custom-consumer', count = 4, style = { width = 8 } }
  local definition = made.define(fields)
  expect.equal(fields.name, 'custom-consumer', 'define leaves the caller fields intact')
  expect.equal(definition.name, 'custom-consumer', 'the defined name')
  expect.equal(made.define({}).name, 'configured-consumer', 'the default name')
  local runtime = plugin.runtime()
  runtime:use(definition, { style = { color = { 0, 0, 1 } } }):enable()
  runtime:use(made.definition, {}):enable()
  expect.equal(observed[1].count, 4, 'the defined count')
  expect.equal(observed[1].style.width, 8, 'the defined nested setting')
  expect.equal(observed[1].style.color[1], 0, 'the runtime list replaces the default')
  expect.equal(observed[1].mode, 'quiet', 'an unchanged setting')
  expect.equal(observed[2].count, 1, 'the original definition retains its count')
  expect.equal(observed[2].style.width, 2, 'the original definition retains nested defaults')
  runtime:close()
end)

test('defaults, defined overrides, and runtime overrides are copied and frozen', function()
  local observed
  local defaults = { count = 1, style = { width = 2, color = { 1, 1, 1 } }, mode = 'quiet' }
  local made = consumer(function(_context, settings)
    observed = settings
  end, defaults)
  defaults.count = 20
  defaults.style.width = 30
  defaults.style.color[1] = 0
  local fields = { style = { color = { 0, 1, 0 } } }
  local definition = made.define(fields)
  fields.style.color[2] = 0
  local config = { style = { width = 7 } }
  local runtime, instance = activate(definition, config)
  expect.equal(instance:state(), 'active', tostring(instance:diagnostic()))
  expect.equal(observed.count, 1, 'the copied default')
  expect.equal(observed.style.width, 7, 'the runtime override')
  expect.equal(observed.style.color[2], 1, 'the copied defined list')
  expect.truthy(table.isfrozen(observed), 'the settings are frozen')
  expect.truthy(table.isfrozen(observed.style), 'nested records are frozen')
  expect.truthy(table.isfrozen(observed.style.color), 'nested lists are frozen')
  expect.falsy(table.isfrozen(defaults), 'the caller defaults remain writable')
  expect.falsy(table.isfrozen(fields.style.color), 'the caller overrides remain writable')
  expect.falsy(table.isfrozen(config), 'the runtime configuration remains writable')
  expect.raises(function()
    observed.style.width = 10
  end, 'readonly')
  runtime:close()
end)

test('consumer declarations are copied and frozen, and init explicitly requires a typed capability', function()
  local capability = plugin.capability { name = 'local/configured-source', schema = 1 }
  local replacement = plugin.capability { name = 'local/configured-unused-source', schema = 1 }
  local requires = { source = capability }
  local marker
  local made = plugin.consumer {
    name = 'configured-require',
    requires = requires,
    init = function(context)
      marker = context:require(capability).marker
    end,
  }
  requires.source = replacement
  expect.equal(made.requires.source, capability, 'the requirement was copied')
  expect.truthy(table.isfrozen(made), 'the consumer module is frozen')
  expect.truthy(table.isfrozen(made.requires), 'the requirements are frozen')
  expect.truthy(table.isfrozen(made.definition), 'the definition is frozen')
  expect.equal(next(made.definition.provides), nil, 'a consumer declares no provisions')
  local runtime = plugin.runtime()
  runtime
    :use(
      plugin.provider({
        name = 'configured-source',
        capability = capability,
        build = function()
          return { marker = 'resolved' }
        end,
      }).definition,
      {}
    )
    :enable()
  runtime:use(made.definition, {}):enable()
  expect.equal(marker, 'resolved', 'the explicit require returns the published service')
  runtime:close()
end)

test('consumer specs reject unknown fields and malformed authoring callbacks', function()
  for _, field in ipairs { 'provides', 'build', 'defualts' } do
    local spec = { name = 'bad-spec', init = function() end }
    spec[field] = {}
    expect.raises(function()
      plugin.consumer(spec)
    end, 'plugin consumer: unknown field ' .. field)
  end
  expect.raises(function()
    plugin.consumer(false)
  end, 'plugin consumer: a consumer is a table of fields, not a boolean')
  expect.raises(function()
    plugin.consumer { name = '', init = function() end }
  end, 'plugin consumer: name is a non%-empty string')
  expect.raises(function()
    plugin.consumer { name = 'bad-init', init = true }
  end, 'plugin consumer: init is a function, not a boolean')
  expect.raises(function()
    plugin.consumer { name = 'bad-validation', validate = {}, init = function() end }
  end, 'plugin consumer: validate is a function, not a table')
end)

test('configured helpers reject a non-table requirement instead of omitting it', function()
  local capability = plugin.capability { name = 'local/configured-malformed-require', schema = 1 }
  for _, requires in { false, true, 42, 'required' } do
    local consumerMessage = expect.raises(function()
      plugin.consumer { name = 'invalid-consumer-requires', requires = requires, init = function() end }
    end, 'requires is a table of capabilities', 'the consumer requirements')
    expect.truthy(consumerMessage:find '@lunette%-plugin/tests/configured.luau:%d+:', consumerMessage)
    local providerMessage = expect.raises(function()
      plugin.provider {
        name = 'invalid-provider-requires',
        capability = capability,
        requires = requires,
        build = function()
          return {}
        end,
      }
    end, 'requires is a table of capabilities', 'the provider requirements')
    expect.truthy(providerMessage:find '@lunette%-plugin/tests/configured.luau:%d+:', providerMessage)
  end
end)

test('configured helpers reject non-table defaults at construction', function()
  local capability = plugin.capability { name = 'local/configured-malformed-defaults', schema = 1 }
  local validated, initialized, built = 0, 0, 0
  for _, defaults in { false, true, 42, 'defaults' } do
    expect.raises(function()
      plugin.consumer {
        name = 'invalid-consumer-defaults',
        defaults = defaults,
        validate = function()
          validated += 1
        end,
        init = function()
          initialized += 1
        end,
      }
    end, 'defaults is a table of options', 'the consumer defaults')
    expect.raises(function()
      plugin.provider {
        name = 'invalid-provider-defaults',
        capability = capability,
        defaults = defaults,
        validate = function()
          validated += 1
        end,
        build = function()
          built += 1
          return {}
        end,
      }
    end, 'defaults is a table of options', 'the provider defaults')
  end
  expect.equal(validated, 0, 'malformed defaults never reach validation')
  expect.equal(initialized, 0, 'malformed defaults never reach init')
  expect.equal(built, 0, 'malformed defaults never reach build')
end)

test('consumer initializers cannot return values and failed activation releases effects', function()
  for _, initReturn in
    {
      function()
        return false
      end,
      function()
        return nil
      end,
      function()
        return {}, nil
      end,
    }
  do
    local released = 0
    local made = plugin.consumer {
      name = 'invalid-consumer-return',
      init = function(context)
        context:effect(function()
          return function()
            released += 1
          end
        end)
        return initReturn()
      end,
    }
    local runtime, instance = activate(made.definition)
    expect.equal(instance:state(), 'failed', 'an initializer return fails the activation')
    expect.equal(released, 1, 'failed activation releases the acquired effect')
    local reports = testing.takeReports()
    expect.equal(#reports, 1, 'the invalid return is reported once')
    expect.truthy(reports[1]:find('initializer must return nothing', 1, true), reports[1])
    runtime:close()
    expect.equal(released, 1, 'closing does not repeat cleanup')
  end
end)

test('define rejects unknown options, wrong types, non-table fields, and invalid names', function()
  local made = consumer()
  expect.raises(function()
    made.define { style = { depth = 1 } }
  end, 'plugin configured%-consumer: unknown option style.depth')
  expect.raises(function()
    made.define { name = 'renamed-consumer', count = 'many' }
  end, 'plugin renamed%-consumer: option count is a number, not a string')
  expect.raises(function()
    made.define(false)
  end, 'define takes a table of options, not a boolean')
  for _, name in ipairs { '', 5, false } do
    expect.raises(function()
      made.define { name = name }
    end, 'define names a definition with a non%-empty string')
  end
  local empty = plugin.consumer { name = 'empty-consumer', init = function() end }
  expect.raises(function()
    empty.define { count = 1 }
  end, 'empty%-consumer takes no options')
end)

test('validation rejects defaults, defined defaults, and runtime configuration before init', function()
  expect.raises(function()
    consumer(nil, { mode = 'invalid' })
  end, 'plugin configured%-consumer: option mode is quiet or visible')
  local initialized = 0
  local made = consumer(function()
    initialized += 1
  end)
  expect.raises(function()
    made.define { name = 'invalid-consumer', mode = 'invalid' }
  end, 'plugin invalid%-consumer: option mode is quiet or visible')
  for _, config in ipairs { { mode = 'invalid' }, { missing = true }, { count = false } } do
    local runtime, instance = activate(made.definition, config)
    expect.equal(instance:state(), 'failed', 'invalid runtime options fail the instance')
    local reports = testing.takeReports()
    expect.equal(#reports, 1, 'the invalid configuration is reported once')
    expect.truthy(reports[1]:find('plugin configured-consumer:', 1, true), reports[1])
    runtime:close()
  end
  expect.equal(initialized, 0, 'invalid settings never reach init')
end)

test('definition construction has no runtime effects, and each activation gets fresh state', function()
  local initialized, acquired, released = 0, 0, 0
  local states = {}
  local made = consumer(function(context)
    initialized += 1
    local state = { count = 0 }
    states[#states + 1] = state
    context:effect(function()
      acquired += 1
      state.count += 1
      return function()
        released += 1
      end
    end)
  end)
  local first, second = made.define {}, made.define { count = 2 }
  expect.equal(initialized, 0, 'constructing definitions does not initialize')
  expect.equal(acquired, 0, 'constructing definitions does not acquire')
  local runtime, instance = activate(first)
  instance:disable()
  instance:enable()
  local other, otherInstance = activate(second)
  expect.equal(otherInstance:state(), 'active', tostring(otherInstance:diagnostic()))
  expect.equal(initialized, 3, 'each activation initializes once')
  expect.equal(acquired, 3, 'each activation acquires once')
  expect.truthy(states[1] ~= states[2] and states[2] ~= states[3], 'activation state is distinct')
  expect.equal(states[1].count, 1, 'the first activation state is unchanged')
  runtime:close()
  other:close()
  expect.equal(released, 3, 'every activation releases its effects')
end)

test('a definition factory retains state across its activations but not across runtimes', function()
  local factories = 0
  local observed = {}
  local function factory()
    factories += 1
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
  local first = plugin.start(entries)
  first.instances['configured-factory']:disable()
  first.instances['configured-factory']:enable()
  first.runtime:close()
  local second = plugin.start(entries)
  expect.equal(factories, 2, 'each runtime calls the factory once')
  expect.equal(table.concat(observed, ','), '1,2,1', 'factory state is isolated per runtime')
  second.runtime:close()
end)

test('provider define and unpublished build share the consumer configuration rules', function()
  local capability = plugin.capability { name = 'local/configured-parity', schema = 1 }
  local built, consumerSettings, service = 0, nil, nil
  local defaults = { count = 1, style = { width = 2 }, mode = 'quiet' }
  local source = plugin.provider {
    name = 'configured-parity-provider',
    capability = capability,
    defaults = defaults,
    validate = validate,
    build = function(_context, settings)
      built += 1
      return { settings = settings }
    end,
  }
  local sink = consumer(function(_context, settings)
    consumerSettings = settings
  end, defaults)
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
          end, 'unknown option style.depth')
          expect.raises(function()
            source.build(context, { mode = 'invalid' })
          end, 'option mode is quiet or visible')
          local unpublished = source.build(context)
          expect.equal(unpublished.settings.count, 1, 'build uses the original provider defaults')
          expect.truthy(unpublished ~= service, 'build returns an unpublished service')
          expect.equal(context:require(capability).settings.count, 6, 'build does not replace the published service')
          expect.truthy(table.isfrozen(unpublished.settings), 'build resolves frozen settings')
        end,
      },
      {}
    )
    :enable()
  expect.equal(service.settings.count, consumerSettings.count, 'the runtime override agrees')
  expect.equal(service.settings.style.width, consumerSettings.style.width, 'the defined nested default agrees')
  expect.equal(service.settings.mode, consumerSettings.mode, 'the unchanged default agrees')
  expect.equal(built, 2, 'only activation and explicit build construct services')
  runtime:close()
end)

return test
