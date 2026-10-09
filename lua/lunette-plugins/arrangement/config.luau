local schema = require '@lunette-plugin/schema'
local state = require '@lunette-plugins/arrangement/state'

local SCHEMA = schema.object {
  file = schema.default(schema.string { minLength = 1 })(state.FILE),
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
