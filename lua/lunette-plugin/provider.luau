-- The shape every built-in provider module exports.
--
-- A provider module answers `definition`, the default instance; `define`,
-- which makes another definition with changed defaults; `build`, which makes
-- the service without publishing it, so a plugin can wrap it; and
-- `requires`, the capabilities `build` reads from its context. The
-- configuration a definition is used with is merged over its defaults and
-- validated against them at every activation.

local adapter = require '@lunette-plugin/adapter'
local options = require '@lunette-plugin/options'

local provider = {}

-- The fields `plugin.provider` accepts. `defaults` is every option with its
-- default value, and `build` receives the resolved options. `validate`, when
-- given, receives the resolved options and the definition's name before
-- `build` or `define` uses them, and raises for what the defaults cannot
-- describe, such as a value outside a closed set or a malformed entry of a
-- list. Its error names the plugin by that name, as option errors do.
export type Spec<S, T> = {
  read name: string,
  read capability: adapter.Capability<T>,
  read requires: adapter.Declaration?,
  read defaults: S,
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
  defaults = true,
  validate = true,
  build = true,
}

function provider.create<C, S, T>(spec: Spec<S, T>): Provider<C, T>
  if type(spec) ~= 'table' then
    error('plugin provider: a provider is a table of fields, not a ' .. type(spec), 3)
  end
  options.rejectUnknownKeys(
    'provider',
    (spec :: unknown) :: { [unknown]: unknown },
    specKeys,
    'name, capability, requires, defaults, validate, and build',
    4
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
  local requires: adapter.Declaration = table.freeze(table.clone(spec.requires or {}))
  local provides: adapter.Declaration = { service = (capability :: unknown) :: any }
  table.freeze(provides)

  local function resolve(label: string, defaults: S, config: unknown): S
    local resolved = options.resolve { name = label, defaults = defaults, config = config }
    if validate then
      validate(resolved, label)
    end
    return resolved
  end

  local function definitionFor(label: string, defaults: S): adapter.Definition<C>
    return adapter.define {
      name = label,
      requires = requires,
      provides = provides,
      init = function(context: adapter.Context, config: C, publish: adapter.Publisher): ()
        publish:provide(capability, build(context, resolve(label, defaults, config)))
      end,
    }
  end

  local defaults = resolve(name, spec.defaults, nil)
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
    build = function(context: adapter.Context, config: C?): T
      return build(context, resolve(name, defaults, config))
    end,
    requires = requires,
  }
end

return provider
