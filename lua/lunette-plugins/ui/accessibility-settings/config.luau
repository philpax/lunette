local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {
  -- Whether the settings panel is open. Opening and closing the panel saves it, so the panel opens at the next start
  -- as it was left.
  visible = schema.default(schema.boolean())(false),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
