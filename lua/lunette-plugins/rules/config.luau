local schema = require '@lunette-plugin/schema'
local vocabulary = require '@lunette-contracts/vocabulary'

local SCHEMA = schema.object {
  precedence = schema.default(schema.number())(vocabulary.PRECEDENCE.rules),
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return SCHEMA
