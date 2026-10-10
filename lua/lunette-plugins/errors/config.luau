local schema = require '@lunette-plugin/schema'

local SCHEMA = schema.object {
  window = schema.default(schema.number { minimum = 0 })(5),
  maxKeys = schema.default(schema.number { minimum = 1, integer = true })(64),
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
