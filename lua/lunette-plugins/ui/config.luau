local schema = require '@lunette-plugin/schema'
local theme = require './theme'
local titlebarStyle = require './titlebar-configuration'

local SCHEMA = schema.object {
  theme = schema.default(theme.editable) {},
  titlebarStyle = schema.default(titlebarStyle.editable) {},
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
