local schema = require '@lunette-plugin/schema'

-- Provider settings are empty. Each reader selects its own shared size/hop profile when it opens.
local SCHEMA = schema.object {}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
