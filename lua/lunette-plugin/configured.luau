-- Shared option resolution and definition construction for configured providers and consumers.

local adapter = require '@lunette-plugin/adapter'
local options = require '@lunette-plugin/options'
local schema = require '@lunette-plugin/schema'

local configured = {}

export type Spec<C, S> = {
  read name: string,
  read requires: adapter.Declaration?,
  read provides: adapter.Declaration?,
  read schema: schema.Schema<C, S>?,
  read defaults: S?,
  read validate: ((S, string) -> ())?,
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
  local name, init, validate, descriptor = spec.name, spec.init, spec.validate, spec.schema
  for _, field in { 'requires', 'provides' } do
    local declaration: unknown = if field == 'requires' then spec.requires else spec.provides
    if declaration ~= nil and type(declaration) ~= 'table' then
      error('plugin ' .. name .. ': ' .. field .. ' is a table of capabilities, not a ' .. type(declaration), 4)
    end
  end
  if descriptor ~= nil and spec.defaults ~= nil then
    error('plugin ' .. name .. ': schema and defaults cannot both be supplied', 4)
  end
  if spec.defaults ~= nil and type(spec.defaults) ~= 'table' then
    error('plugin ' .. name .. ': defaults is a table of options, not a ' .. type(spec.defaults), 4)
  end
  if descriptor ~= nil then
    -- Constructors reject forged descriptors before any caller-provided method is invoked.
    schema.optional(descriptor)
  end
  local requires: adapter.Declaration = table.freeze(table.clone(spec.requires or {}))
  local provides: adapter.Declaration = table.freeze(table.clone(spec.provides or {}))

  local function checked(label: string, settings: S): S
    if validate then
      validate(settings, label)
    end
    return settings
  end

  local function resolve(label: string, defaults: S, config: unknown): S
    if descriptor then
      return checked(label, descriptor.resolve(config, defaults, label))
    end
    return checked(label, options.resolve { name = label, defaults = defaults, config = config })
  end

  local function definitionFor(label: string, defaults: S): adapter.Definition<C>
    local metadata: schema.Metadata? = nil
    if descriptor then
      local node = descriptor.inspect()
      metadata = table.freeze {
        kind = 'default' :: 'default',
        child = node,
        value = defaults,
        readOnly = node.readOnly,
        merge = node.merge,
        label = node.label,
        description = node.description,
      }
    end
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

  local defaults: S
  if descriptor then
    defaults = checked(name, descriptor.parse({}, name))
  else
    defaults = resolve(name, spec.defaults or (({} :: unknown) :: S), nil)
  end
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

return configured
