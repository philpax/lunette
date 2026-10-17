local schema = require '@lunette-plugin/schema'

local SCHEMA = schema.object {
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
