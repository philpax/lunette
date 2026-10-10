-- Native panels use the shared UI titlebar style, with an optional desktop override.
local schema = require '@lunette-plugin/schema'
local titlebarStyle = require '@lunette-plugins/ui/titlebar-style'

local descriptor = schema.object {
  style = schema.optional(titlebarStyle.editable),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
