local schema = require '@lunette-plugin/schema'
local ui = require '@lunette-contracts/ui'
local theme = require './theme'
local titlebarStyle = require './titlebar-style'

-- The schema types the optional provider hook from this signature.
local function drawHook(_pass: Pass, _visual: ui.Visual, _base: ui.Renderer): () end

local SCHEMA = schema.object {
  theme = schema.default(theme.editable) {},
  titlebarStyle = schema.default(titlebarStyle.editable) {},
  draw = schema.optional(schema.callback(drawHook)),
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
