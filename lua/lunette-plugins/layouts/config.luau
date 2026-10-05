local schema = require '@lunette-plugin/schema'

local SCHEMA = schema.object {}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return SCHEMA
