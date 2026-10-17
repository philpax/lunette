local schema = require '@lunette-plugin/schema'

local color = schema.array(schema.number { minimum = 0, maximum = 1 }, { minLength = 3, maxLength = 4 })

-- The mode and accent apply until the user changes them in a session; the change is saved to the file and applies at
-- the next start instead.
local SCHEMA = schema.object {
  mode = schema.default(schema.enum<<'dark' | 'light'>> { 'dark', 'light' }) 'dark',
  -- sRGB components; the theme guards the accent's contrast against the surface.
  accent = schema.optional(color),
  -- The settings file in LÖVR's save directory.
  file = schema.default(schema.string { minLength = 1 }) 'theme.settings',
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
