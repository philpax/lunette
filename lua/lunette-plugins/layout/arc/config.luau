local schema = require '@lunette-plugin/schema'
local geometry = require '@lunette-plugins/layout/arc/geometry'

local TUNING = schema.object {
  radius = schema.default(schema.number { minimum = 0 })(1.6),
  step = schema.default(schema.number { minimum = 0 })(0.55),
  span = schema.default(schema.number { minimum = 0 })(math.pi * 1.2),
  gap = schema.default(schema.number { minimum = 0 })(0.05),
  center = schema.default(schema.vector())(vector.pack(0, 1.5, 0)),
}
local CHECKED_TUNING = schema.refine(TUNING)(function(tuning)
  geometry.validate(tuning, 'layout/arc')
end, 'A positive radius and nonnegative angular step, span, and edge gap.')
local SCHEMA = schema.object {
  layout = schema.default(schema.string { minLength = 1 }) 'arc',
  tuning = schema.default(CHECKED_TUNING)(CHECKED_TUNING.parse {}),
}

export type Options = schema.Input<typeof(TUNING)>
export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return table.freeze { schema = SCHEMA, tuning = CHECKED_TUNING }
