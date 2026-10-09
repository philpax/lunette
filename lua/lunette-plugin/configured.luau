-- Shared option resolution and definition construction for configured providers and consumers.

local adapter = require '@lunette-plugin/adapter'
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

-- A spec without a schema takes no options.
function configured.create<C, S>(spec: Spec<C, S>): Configured<C, S>
  local name, init = spec.name, spec.init
  for _, field in { 'requires', 'provides' } do
    local declaration: unknown = if field == 'requires' then spec.requires else spec.provides
    if declaration ~= nil and type(declaration) ~= 'table' then
      error('plugin ' .. name .. ': ' .. field .. ' is a table of capabilities, not a ' .. type(declaration), 4)
    end
  end
  local descriptor: schema.Schema<C, S> = if spec.schema == nil then schema.object {} :: any else spec.schema
  -- Constructors reject forged descriptors before any caller-provided method is invoked.
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

return configured
