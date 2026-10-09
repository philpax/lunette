local schema = require '@lunette-plugin/schema'

-- The timer is read at each call, because the test harness replaces lovr.timer after this module loads.
local function clock(): number
  return lovr.timer.getTime()
end

local SCHEMA = schema.object {
  window = schema.default(schema.number { minimum = 0 })(5),
  maxKeys = schema.default(schema.number { minimum = 1, integer = true })(64),
  history = schema.default(schema.number { minimum = 1, integer = true })(32),
  clock = schema.default(schema.callback(clock))(clock),
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return SCHEMA
