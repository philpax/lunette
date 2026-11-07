local schema = require '@lunette-plugin/schema'

local placement = schema.object {
  distance = schema.default(schema.number())(0.55),
  drop = schema.default(schema.number())(0.35),
  tilt = schema.default(schema.number())(math.pi / 6),
}
-- Where earlier versions saved the keyboard. Placement memory now keeps it, so the display accepts and ignores this.
local positive = schema.number { positive = true }
local placed = schema.object {
  position = schema.vector(),
  rotation = schema.array(schema.number(), { minLength = 4, maxLength = 4 }),
  width = schema.optional(positive),
  height = schema.optional(positive),
}
local descriptor = schema.object {
  placement = schema.default(placement)(placement.parse {}),
  placed = schema.optional(placed),
  -- Saved by the display: whether the keyboard was shown by an explicit show action. Such a keyboard shows again when
  -- the session starts or reloads, and placement memory returns it to where it was left.
  shown = schema.default(schema.boolean())(false),
}

export type Placement = schema.Output<typeof(placement)>
export type Placed = schema.Output<typeof(placed)>
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
