local schema = require '@lunette-plugin/schema'
local ui = require '@lunette-contracts/ui'
local theme = require './theme'
local titlebarStyle = require './titlebar-style'

local function passthrough(pass: Pass, visual: ui.Visual, base: ui.Renderer): ()
  base(pass, visual)
end

local SCHEMA = schema.object {
  theme = schema.default(theme.editable) {},
  titlebarStyle = schema.default(titlebarStyle.editable) {},
  draw = schema.default(schema.callback(passthrough))(passthrough),
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return SCHEMA
