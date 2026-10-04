-- Shared option resolution and definition construction for configured providers and consumers.

local adapter = require '@lunette-plugin/adapter'
local options = require '@lunette-plugin/options'

local configured = {}

export type Spec<S> = {
  read name: string,
  read requires: adapter.Declaration?,
  read provides: adapter.Declaration?,
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

function configured.create<C, S>(spec: Spec<S>): Configured<C, S>
  local name, init, validate = spec.name, spec.init, spec.validate
  for _, field in { 'requires', 'provides' } do
    local declaration: unknown = if field == 'requires' then spec.requires else spec.provides
    if declaration ~= nil and type(declaration) ~= 'table' then
      error('plugin ' .. name .. ': ' .. field .. ' is a table of capabilities, not a ' .. type(declaration), 4)
    end
  end
  if spec.defaults ~= nil and type(spec.defaults) ~= 'table' then
    error('plugin ' .. name .. ': defaults is a table of options, not a ' .. type(spec.defaults), 4)
  end
  local requires: adapter.Declaration = table.freeze(table.clone(spec.requires or {}))
  local provides: adapter.Declaration = table.freeze(table.clone(spec.provides or {}))

  local function resolve(label: string, defaults: S, config: unknown): S
    local settings = options.resolve { name = label, defaults = defaults, config = config }
    if validate then
      validate(settings, label)
    end
    return settings
  end

  local function definitionFor(label: string, defaults: S): adapter.Definition<C>
    return adapter.define {
      name = label,
      requires = requires,
      provides = provides,
      init = function(context: adapter.Context, config: C, publish: adapter.Publisher): ()
        return init(context, resolve(label, defaults, config), publish)
      end,
    }
  end

  local defaults = resolve(name, spec.defaults or ({} :: any), nil)
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
