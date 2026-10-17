local schema = require '@lunette-plugin/schema'

local positive = schema.number { positive = true }
local hand = schema.enum<<'left' | 'right'>> { 'left', 'right' }
local expanded = schema.object {
  width = schema.default(positive)(0.32),
  height = schema.default(positive)(0.4),
}
local descriptor = schema.object {
  hand = schema.default(hand) 'left',
  size = schema.default(positive)(0.115),
  offset = schema.default(schema.vector())(vector.pack(-0.03, -0.01, 0.125)),
  expanded = schema.default(expanded)(expanded.parse {}),
}

export type Hand = schema.Output<typeof(hand)>
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
