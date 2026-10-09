local schema = require '@lunette-plugin/schema'

local placement = schema.object {
  distance = schema.default(schema.number())(0.55),
  drop = schema.default(schema.number())(0.35),
  tilt = schema.default(schema.number())(math.pi / 6),
}
local descriptor = schema.object {
  placement = schema.default(placement)(placement.parse {}),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
