-- Configured definitions: a schema resolves a caller's options into the settings an initializer receives.

local adapter = require '@lunette-plugin/adapter'
local fields = require '@lunette-plugin/fields'
local schema = require '@lunette-plugin/schema'

local configured = {}

export type ProviderSpec<C, S, T> = {
  read name: string,
  read capability: adapter.Capability<T>,
  read requires: adapter.Declaration?,
  read schema: schema.Schema<C, S>?,
  read build: (adapter.Context, S) -> T,
}

-- C describes optional overrides. `definition` uses the default settings, and `define` binds other defaults.
export type Provider<C> = {
  read definition: adapter.Definition<C>,
  read define: (C & { read name: string? }) -> adapter.Definition<C>,
}

export type ConsumerSpec<C, S> = {
  read name: string,
  read requires: adapter.Declaration?,
  read schema: schema.Schema<C, S>?,
  read init: (adapter.Context, S) -> (),
}

export type Consumer<C> = Provider<C>

type Spec<C, S> = {
  read name: string,
  read requires: adapter.Declaration?,
  read provides: adapter.Declaration?,
  read schema: schema.Schema<C, S>?,
  read init: (adapter.Context, S, adapter.Publisher) -> (),
}

-- `callback` names the function field.
local function checkSpec(kind: string, spec: unknown, allowed: { string }, callback: string): ()
  local prefix = 'plugin ' .. kind
  if type(spec) ~= 'table' then
    error(prefix .. ': a ' .. kind .. ' is a table of fields, not a ' .. type(spec), 4)
  end
  fields.rejectUnknownFields(prefix, spec, allowed, 4)
  local raw = spec :: { [string]: unknown }
  if type(raw.name) ~= 'string' or raw.name == '' then
    error(prefix .. ': name is a non-empty string, not ' .. tostring(raw.name), 4)
  end
  if type(raw[callback]) ~= 'function' then
    error(prefix .. ': ' .. callback .. ' is a function, not a ' .. type(raw[callback]), 4)
  end
end

local function create<C, S>(spec: Spec<C, S>): Provider<C>
  local name, init = spec.name, spec.init
  local descriptor: schema.Schema<C, S> = if spec.schema == nil then schema.object {} :: any else spec.schema
  -- Rejects a forged descriptor before any of its methods run.
  schema.optional(descriptor)
  local requires, provides = spec.requires, spec.provides

  local function resolve(label: string, defaults: S, config: unknown): S
    return descriptor.resolve(config, defaults, 'plugin ' .. label)
  end

  local function definitionFor(label: string, defaults: S): adapter.Definition<C>
    local node = descriptor.inspect()
    local metadata: schema.Metadata = table.freeze {
      kind = 'default' :: 'default',
      child = node,
      value = defaults,
      readOnly = node.readOnly,
      merge = node.merge,
      label = node.label,
      description = node.description,
    }
    return adapter.define({
      name = label,
      requires = requires,
      provides = provides,
      init = function(context: adapter.Context, config: C, publish: adapter.Publisher): ()
        return init(context, resolve(label, defaults, config), publish)
      end,
    }, {
      schema = metadata,
      resolve = function(config: unknown): unknown
        return resolve(label, defaults, config)
      end,
    })
  end

  local defaults: S = descriptor.parse({}, 'plugin ' .. name)
  return table.freeze {
    definition = definitionFor(name, defaults),
    define = function(given: C & { read name: string? }): adapter.Definition<C>
      if type(given) ~= 'table' then
        error('plugin ' .. name .. ': define takes a table of options, not a ' .. type(given), 2)
      end
      local options = table.clone((given :: unknown) :: { [string]: unknown })
      local label = options.name
      options.name = nil
      if label == nil then
        label = name
      elseif type(label) ~= 'string' or label == '' then
        error('plugin ' .. name .. ': define names a definition with a non-empty string, not ' .. tostring(label), 2)
      end
      return definitionFor(label :: string, resolve(label :: string, defaults, options))
    end,
  }
end

function configured.provider<C, S, T>(spec: ProviderSpec<C, S, T>): Provider<C>
  checkSpec('provider', spec, { 'name', 'capability', 'requires', 'schema', 'build' }, 'build')
  local capability, build = spec.capability, spec.build
  return create<<C, S>> {
    name = spec.name,
    requires = spec.requires,
    provides = { capability },
    schema = spec.schema,
    init = function(context: adapter.Context, settings: S, publish: adapter.Publisher): ()
      publish:provide(capability, build(context, settings))
    end,
  }
end

function configured.consumer<C, S>(spec: ConsumerSpec<C, S>): Consumer<C>
  checkSpec('consumer', spec, { 'name', 'requires', 'schema', 'init' }, 'init')
  local init = spec.init
  return create<<C, S>> {
    name = spec.name,
    requires = spec.requires,
    schema = spec.schema,
    init = function(context: adapter.Context, settings: S, _publish: adapter.Publisher): ()
      return init(context, settings)
    end,
  }
end

return configured
