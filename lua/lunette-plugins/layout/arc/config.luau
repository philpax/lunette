local schema = require '@lunette-plugin/schema'

local TUNING = schema.object {
  radius = schema.default(schema.number { positive = true })(1.6),
  step = schema.default(schema.number { minimum = 0 })(0.55),
  span = schema.default(schema.number { minimum = 0 })(math.pi * 1.2),
  gap = schema.default(schema.number { minimum = 0 })(0.05),
  center = schema.default(schema.vector())(vector.pack(0, 1.5, 0)),
}
local SCHEMA = schema.object {
  -- The name the layout registers under.
  name = schema.default(schema.string { minLength = 1 }) 'arc',
  tuning = schema.default(TUNING)(TUNING.parse {}),
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
