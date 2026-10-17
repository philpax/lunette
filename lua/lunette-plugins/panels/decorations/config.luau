-- Titlebars take their appearance from the toolkit theme; only their height can be set here.
local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {
  -- Metres; the theme's header height when unset.
  height = schema.optional(schema.number { positive = true }),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
