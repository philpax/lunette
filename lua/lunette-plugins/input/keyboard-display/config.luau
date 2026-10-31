local schema = require '@lunette-plugin/schema'

local placement = schema.object {
  distance = schema.default(schema.number())(0.55),
  drop = schema.default(schema.number())(0.35),
  tilt = schema.default(schema.number())(math.pi / 6),
}
-- Where the keyboard was left: its position, its rotation as an angle about an axis, and its size in metres, which a
-- resize changes.
local positive = schema.number { positive = true }
local placed = schema.object {
  position = schema.vector(),
  rotation = schema.array(schema.number(), { minLength = 4, maxLength = 4 }),
  width = schema.optional(positive),
  height = schema.optional(positive),
}
local descriptor = schema.object {
  placement = schema.default(placement)(placement.parse {}),
  -- Saved by the display: where the keyboard last came to rest, and whether it was shown by an explicit show action.
  -- A keyboard that was shown so returns there when the session starts or reloads.
  placed = schema.optional(placed),
  shown = schema.default(schema.boolean())(false),
}

export type Placement = schema.Output<typeof(placement)>
export type Placed = schema.Output<typeof(placed)>
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
