-- The backdrop has a linear-light palette independent of the desktop UI theme.
local schema = require '@lunette-plugin/schema'

local color = schema.array(schema.number { minimum = 0, maximum = 1 }, { minLength = 3, maxLength = 3 })
local palette = schema.object {
  zenith = schema.default(color) { 0.006, 0.012, 0.028 },
  horizon = schema.default(color) { 0.012, 0.022, 0.03 },
  low = schema.default(color) { 0.05, 0.52, 0.24 },
  high = schema.default(color) { 0.12, 0.18, 0.45 },
  glint = schema.default(color) { 0.4, 0.65, 0.6 },
  -- Each coarse audio band lights the curtains and colours its onset action in its own hue.
  bass = schema.default(color) { 0.62, 0.04, 0.24 },
  mid = schema.default(color) { 0.06, 0.62, 0.26 },
  treble = schema.default(color) { 0.3, 0.36, 0.95 },
}
local descriptor = schema.object {
  enabled = schema.default(schema.boolean())(true),
  reactive = schema.default(schema.boolean())(true),
  sourceMode = schema.default(
    schema.enum<<'system' | 'application' | 'attention'>> { 'system', 'application', 'attention' }
  ) 'system',
  dwell = schema.default(schema.number { minimum = 0.1, maximum = 3 })(0.75),
  fadeDuration = schema.default(schema.number { minimum = 0, maximum = 5 })(0.8),
  attackDuration = schema.default(schema.number { minimum = 0, maximum = 5 })(0.06),
  releaseDuration = schema.default(schema.number { minimum = 0, maximum = 5 })(0.45),
  crossfadeDuration = schema.default(schema.number { minimum = 0, maximum = 5 })(1.2),
  recoveryDuration = schema.default(schema.number { minimum = 0, maximum = 5 })(1.5),
  distance = schema.default(schema.number { minimum = 15, maximum = 40 })(25),
  quality = schema.default(schema.enum<<'low' | 'standard' | 'high'>> { 'low', 'standard', 'high' }) 'standard',
  brightness = schema.default(schema.number { minimum = 0, maximum = 1 })(0.7),
  response = schema.default(schema.number { minimum = 0, maximum = 1 })(0.7),
  motion = schema.default(schema.number { minimum = 0, maximum = 1 })(0.35),
  palette = schema.default(palette)(palette.parse {}),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
