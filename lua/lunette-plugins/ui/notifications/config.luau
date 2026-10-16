local schema = require '@lunette-plugin/schema'

local SCHEMA = schema.object {
  -- Seconds a toast stays when the notification gives no timeout.
  timeout = schema.default(schema.number { positive = true })(6),
  -- Multiplies every timeout, for users who need more time to read.
  timing = schema.default(schema.number { positive = true })(1),
  -- Toasts shown at once; further notifications wait their turn rather than being dropped.
  visible = schema.default(schema.number { positive = true })(3),
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
