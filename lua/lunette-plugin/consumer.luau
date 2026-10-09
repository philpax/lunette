-- Configured consumers expose a default definition, a definition with other defaults, and their requirements.

local adapter = require '@lunette-plugin/adapter'
local configured = require '@lunette-plugin/configured'
local options = require '@lunette-plugin/options'
local schema = require '@lunette-plugin/schema'

local consumer = {}

export type Spec<C, S> = {
  read name: string,
  read requires: adapter.Declaration?,
  read schema: schema.Schema<C, S>?,
  read init: (adapter.Context, S) -> (),
}

-- C is the optional configuration a caller writes; init receives resolved settings instead.
export type Consumer<C> = {
  read definition: adapter.Definition<C>,
  read define: (C & { read name: string? }) -> adapter.Definition<C>,
  read requires: adapter.Declaration,
}

local specKeys: { [string]: boolean } = {
  name = true,
  requires = true,
  schema = true,
  init = true,
}

function consumer.create<C, S>(spec: Spec<C, S>): Consumer<C>
  if type(spec) ~= 'table' then
    error('plugin consumer: a consumer is a table of fields, not a ' .. type(spec), 3)
  end
  options.rejectUnknownFields('plugin consumer', spec, specKeys, 'name, requires, schema, and init', 3)
  local name, init = spec.name, spec.init
  if type(name) ~= 'string' or name == '' then
    error('plugin consumer: name is a non-empty string, not ' .. tostring(name), 3)
  end
  if type(init) ~= 'function' then
    error('plugin consumer: init is a function, not a ' .. type(init), 3)
  end
  local made = configured.create<<C, S>> {
    name = name,
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

return consumer
