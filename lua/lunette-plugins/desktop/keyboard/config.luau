local schema = require '@lunette-plugin/schema'

local positive = schema.refine(schema.number())(function(value: number): ()
  assert(value > 0, 'must be a positive number')
end)
local hand = schema.union(schema.literal<<'left'>> 'left', schema.literal<<'right'>> 'right')
local placement = schema.object {
  distance = schema.default(schema.number())(0.55),
  drop = schema.default(schema.number())(0.35),
  tilt = schema.default(schema.number())(math.pi / 6),
}
local haptic = schema.object {
  strength = schema.default(schema.number())(0.3),
  duration = schema.default(schema.number())(0.05),
}
local descriptor = schema.object {
  hand = schema.default(hand) 'left',
  size = schema.default(positive)(0.115),
  offset = schema.default(schema.vector())(vector.pack(-0.03, -0.01, 0.125)),
  placement = schema.default(placement)(placement.parse {}),
  haptic = schema.default(haptic)(haptic.parse {}),
}

export type Hand = schema.Output<typeof(hand)>
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
