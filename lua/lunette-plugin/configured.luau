-- Configured definitions: a schema resolves a caller's options into the settings an initializer receives.

local adapter = require '@lunette-plugin/adapter'
local options = require '@lunette-plugin/options'
local schema = require '@lunette-plugin/schema'

local configured = {}

export type Spec<C, S> = {
  read name: string,
  read requires: adapter.Declaration?,
  read provides: adapter.Declaration?,
  read schema: schema.Schema<C, S>?,
  read init: (adapter.Context, S, adapter.Publisher) -> (),
}

-- C describes optional overrides; S describes the resolved settings passed to init.
export type Configured<C, S> = {
  read definition: adapter.Definition<C>,
  read define: (C & { read name: string? }) -> adapter.Definition<C>,
  read resolve: (C?) -> S,
  read requires: adapter.Declaration,
}

function configured.create<C, S>(spec: Spec<C, S>): Configured<C, S>
  local name, init = spec.name, spec.init
  for _, field in { 'requires', 'provides' } do
    local declaration: unknown = if field == 'requires' then spec.requires else spec.provides
    if declaration ~= nil and type(declaration) ~= 'table' then
      error('plugin ' .. name .. ': ' .. field .. ' is a table of capabilities, not a ' .. type(declaration), 4)
    end
  end
  local descriptor: schema.Schema<C, S> = if spec.schema == nil then schema.object {} :: any else spec.schema
  -- Rejects a forged descriptor before any of its methods run.
  schema.optional(descriptor)
  local requires: adapter.Declaration = table.freeze(table.clone(spec.requires or {}))
  local provides: adapter.Declaration = table.freeze(table.clone(spec.provides or {}))

  local function resolve(label: string, defaults: S, config: unknown): S
    return descriptor.resolve(config, defaults, label)
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

  local defaults: S = descriptor.parse({}, name)
  return table.freeze {
    definition = definitionFor(name, defaults),
    define = function(fields: C & { read name: string? }): adapter.Definition<C>
      if type(fields) ~= 'table' then
        error('plugin ' .. name .. ': define takes a table of options, not a ' .. type(fields), 2)
      end
      local given = table.clone((fields :: unknown) :: { [string]: unknown })
      local label = given.name
      given.name = nil
      if label == nil then
        label = name
      elseif type(label) ~= 'string' or label == '' then
        error('plugin ' .. name .. ': define names a definition with a non-empty string, not ' .. tostring(label), 2)
      end
      return definitionFor(label :: string, resolve(label :: string, defaults, given))
    end,
    resolve = function(config: C?): S
      return resolve(name, defaults, config)
    end,
    requires = requires,
  }
end

export type ProviderSpec<C, S, T> = {
  read name: string,
  read capability: adapter.Capability<T>,
  read requires: adapter.Declaration?,
  read schema: schema.Schema<C, S>?,
  read build: (adapter.Context, S) -> T,
}

-- `definition` uses the default settings. `build` makes an unpublished service that another plugin can wrap.
export type Provider<C, T> = {
  read definition: adapter.Definition<C>,
  read define: (C & { read name: string? }) -> adapter.Definition<C>,
  read build: (adapter.Context, C?) -> T,
  read requires: adapter.Declaration,
}

export type ConsumerSpec<C, S> = {
  read name: string,
  read requires: adapter.Declaration?,
  read schema: schema.Schema<C, S>?,
  read init: (adapter.Context, S) -> (),
}

export type Consumer<C> = {
  read definition: adapter.Definition<C>,
  read define: (C & { read name: string? }) -> adapter.Definition<C>,
  read requires: adapter.Declaration,
}

local providerKeys: { [string]: boolean } =
  { name = true, capability = true, requires = true, schema = true, build = true }
local consumerKeys: { [string]: boolean } = { name = true, requires = true, schema = true, init = true }

-- `fields` lists the allowed keys for the error message; `callback` names the function field.
local function checkSpec(
  kind: string,
  spec: unknown,
  allowed: { [string]: boolean },
  fields: string,
  callback: string
): ()
  local prefix = 'plugin ' .. kind
  if type(spec) ~= 'table' then
    error(prefix .. ': a ' .. kind .. ' is a table of fields, not a ' .. type(spec), 4)
  end
  options.rejectUnknownFields(prefix, spec, allowed, fields, 4)
  local raw = spec :: { [string]: unknown }
  if type(raw.name) ~= 'string' or raw.name == '' then
    error(prefix .. ': name is a non-empty string, not ' .. tostring(raw.name), 4)
  end
  if type(raw[callback]) ~= 'function' then
    error(prefix .. ': ' .. callback .. ' is a function, not a ' .. type(raw[callback]), 4)
  end
end

function configured.provider<C, S, T>(spec: ProviderSpec<C, S, T>): Provider<C, T>
  checkSpec('provider', spec, providerKeys, 'name, capability, requires, schema, and build', 'build')
  local capability, build = spec.capability, spec.build
  local made = configured.create<<C, S>> {
    name = spec.name,
    requires = spec.requires,
    provides = { service = capability },
    schema = spec.schema,
    init = function(context: adapter.Context, settings: S, publish: adapter.Publisher): ()
      publish:provide(capability, build(context, settings))
    end,
  }
  return table.freeze {
    definition = made.definition,
    define = made.define,
    build = function(context: adapter.Context, config: C?): T
      return build(context, made.resolve(config))
    end,
    requires = made.requires,
  }
end

function configured.consumer<C, S>(spec: ConsumerSpec<C, S>): Consumer<C>
  checkSpec('consumer', spec, consumerKeys, 'name, requires, schema, and init', 'init')
  local init = spec.init
  local made = configured.create<<C, S>> {
    name = spec.name,
    requires = spec.requires,
    schema = spec.schema,
    init = function(context: adapter.Context, settings: S, _publish: adapter.Publisher): ()
      return init(context, settings)
    end,
  }
  return table.freeze {
    definition = made.definition,
    define = made.define,
    requires = made.requires,
  }
end

return configured
