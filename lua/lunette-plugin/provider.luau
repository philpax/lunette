-- The shape every built-in provider module exports: `definition`, the default instance; `define`, for other
-- defaults; `build`, which makes the service unpublished so a plugin can wrap it; and `requires`.

local adapter = require '@lunette-plugin/adapter'
local configured = require '@lunette-plugin/configured'
local options = require '@lunette-plugin/options'
local schema = require '@lunette-plugin/schema'

local provider = {}

-- `build` receives settings resolved by a schema or legacy defaults. An optional validator checks
-- additional constraints. A provider without options may take the context alone.
export type Spec<C, S, T> = {
  read name: string,
  read capability: adapter.Capability<T>,
  read requires: adapter.Declaration?,
  read schema: schema.Schema<C, S>?,
  read defaults: S?,
  read validate: ((S, string) -> ())?,
  read build: (adapter.Context, S) -> T,
}

-- A provider module. `C` is the configuration a caller writes, every option
-- optional, and `T` is the service.
export type Provider<C, T> = {
  read definition: adapter.Definition<C>,
  read define: (C & { read name: string? }) -> adapter.Definition<C>,
  read build: (adapter.Context, C?) -> T,
  read requires: adapter.Declaration,
}

local specKeys: { [string]: boolean } = {
  name = true,
  capability = true,
  requires = true,
  schema = true,
  defaults = true,
  validate = true,
  build = true,
}

function provider.create<C, S, T>(spec: Spec<C, S, T>): Provider<C, T>
  if type(spec) ~= 'table' then
    error('plugin provider: a provider is a table of fields, not a ' .. type(spec), 3)
  end
  options.rejectUnknownFields(
    'plugin provider',
    spec,
    specKeys,
    'name, capability, requires, schema, defaults, validate, and build',
    3
  )
  local name, capability, build = spec.name, spec.capability, spec.build
  if type(name) ~= 'string' or name == '' then
    error('plugin provider: name is a non-empty string, not ' .. tostring(name), 3)
  end
  if type(build) ~= 'function' then
    error('plugin provider: build is a function, not a ' .. type(build), 3)
  end
  local validate = spec.validate
  if validate ~= nil and type(validate) ~= 'function' then
    error('plugin provider: validate is a function, not a ' .. type(validate), 3)
  end
  local made = configured.create<<C, S>> {
    name = name,
    requires = spec.requires,
    provides = { service = capability },
    schema = spec.schema,
    defaults = spec.defaults,
    validate = validate,
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

return provider
