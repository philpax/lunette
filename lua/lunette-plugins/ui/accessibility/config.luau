local schema = require '@lunette-plugin/schema'
local accessibility = require '@lunette-contracts/accessibility'

local DEFAULTS = accessibility.DEFAULTS

-- The settings start from these, and a change made in a session is saved and replaces them at the next start.
local SCHEMA = schema.object {
  reducedMotion = schema.default(schema.boolean())(DEFAULTS.reducedMotion),
  textScale = schema.default(schema.number { minimum = 0.5, maximum = 2 })(DEFAULTS.textScale),
  highContrast = schema.default(schema.boolean())(DEFAULTS.highContrast),
  timing = schema.default(schema.number { minimum = 0.5, maximum = 5 })(DEFAULTS.timing),
  haptics = schema.default(schema.boolean())(DEFAULTS.haptics),
  sounds = schema.default(schema.boolean())(DEFAULTS.sounds),
  handedness = schema.default(schema.enum<<'left' | 'right'>> { 'left', 'right' })(DEFAULTS.handedness),
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
