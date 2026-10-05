local schema = require '@lunette-plugin/schema'

export type IdealBase = (number) -> number
export type Ideal = (number, IdealBase) -> number

local function ideal(distance: number, base: IdealBase): number
  return base(distance)
end

local TUNING = schema.object {
  -- Scale varies inversely with distance from this reference.
  reference = schema.default(schema.number { minimum = 0 })(1),
  -- The wider lower margin reduces oscillation near a rung.
  raise = schema.default(schema.number { minimum = 0 })(0.06),
  lower = schema.default(schema.number { minimum = 0, maximum = 1 })(0.12),
  nearest = schema.default(schema.number { minimum = 0 })(0.05),
}
local SCHEMA = schema.object {
  tuning = schema.default(TUNING)(TUNING.parse {}),
  ideal = schema.default(schema.callback(ideal))(ideal),
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return SCHEMA
