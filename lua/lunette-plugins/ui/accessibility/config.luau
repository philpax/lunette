local schema = require '@lunette-plugin/schema'

local SCHEMA = schema.object {
  -- The settings file in LÖVR's save directory.
  file = schema.default(schema.string { minLength = 1 }) 'accessibility.settings',
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
