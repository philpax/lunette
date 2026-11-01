local schema = require '@lunette-plugin/schema'

-- Where a surface was left: its position, its rotation as an angle about an axis, and its width in metres for a
-- surface that can be resized.
local placement = schema.object {
  position = schema.vector(),
  rotation = schema.array(schema.number(), { minLength = 4, maxLength = 4 }),
  width = schema.optional(schema.number { positive = true }),
}

local descriptor = schema.object {
  -- Saved by the plugin: each keyed surface's placement, by placement key, written when the surface is dropped.
  placed = schema.default(schema.map(placement)) {},
}

export type Placement = schema.Output<typeof(placement)>
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
