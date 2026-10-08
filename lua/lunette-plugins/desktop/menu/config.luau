local schema = require '@lunette-plugin/schema'

local positive = schema.refine(schema.number())(function(value: number): ()
  assert(value > 0, 'must be a positive number')
end)
local logicalWidth = schema.refine(positive)(function(value: number): ()
  assert(value >= 120, 'must be at least 120 logical pixels')
end)
local logicalHeight = schema.refine(positive)(function(value: number): ()
  assert(value >= 160, 'must be at least 160 logical pixels')
end)
local strength = schema.refine(schema.number())(function(value: number): ()
  assert(value >= 0 and value <= 1, 'must be between zero and one')
end)
local duration = schema.refine(schema.number())(function(value: number): ()
  assert(value >= 0, 'must be nonnegative')
end)
local hand = schema.union(schema.literal<<'left'>> 'left', schema.literal<<'right'>> 'right')
local haptic = schema.object {
  strength = schema.default(strength)(0.3),
  duration = schema.default(duration)(0.05),
}
local expanded = schema.object {
  width = schema.default(positive)(0.32),
  height = schema.default(positive)(0.4),
  logicalWidth = schema.default(logicalWidth)(320),
  logicalHeight = schema.default(logicalHeight)(400),
  rowHeight = schema.optional(positive),
}
local descriptor = schema.object {
  hand = schema.default(hand) 'left',
  size = schema.default(positive)(0.115),
  offset = schema.default(schema.vector())(vector.pack(-0.03, -0.01, 0.125)),
  haptic = schema.default(haptic)(haptic.parse {}),
  expanded = schema.default(expanded)(expanded.parse {}),
}

export type Hand = schema.Output<typeof(hand)>
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
