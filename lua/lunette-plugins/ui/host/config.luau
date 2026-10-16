local schema = require '@lunette-plugin/schema'

local color = schema.array(schema.number { minimum = 0, maximum = 1 }, { minLength = 3, maxLength = 4 })

local SCHEMA = schema.object {
  mode = schema.default(schema.enum<<'dark' | 'light'>> { 'dark', 'light' }) 'dark',
  -- sRGB components; the theme guards the accent's contrast against the surface.
  accent = schema.optional(color),
  -- Tracked bare fingertips press nodes by touch.
  touch = schema.default(schema.boolean())(true),
  -- A controller's thumbstick and face buttons traverse the panel that holds session focus.
  controllerTraversal = schema.default(schema.boolean())(true),
  -- Holding both thumbstick clicks toggles default appearance.
  appearanceChord = schema.default(schema.boolean())(true),
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
