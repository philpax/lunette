local schema = require '@lunette-plugin/schema'

-- Where a grab left a world panel: its position and its rotation as an angle about an axis.
local PLACEMENT = schema.object {
  position = schema.vector(),
  rotation = schema.array(schema.number(), { minLength = 4, maxLength = 4 }),
}

local SCHEMA = schema.object {
  -- Where the user left each grabbable world panel, by panel name. The host saves it once a grabbed panel settles,
  -- and a panel made with that name opens there instead of at its owner's pose.
  placed = schema.default(schema.map(PLACEMENT)) {},
  -- Tracked bare fingertips press nodes by touch.
  touch = schema.default(schema.boolean())(true),
  -- A controller's thumbstick and face buttons traverse the panel that holds session focus.
  controllerTraversal = schema.default(schema.boolean())(true),
  -- Holding both thumbstick clicks toggles default appearance.
  appearanceChord = schema.default(schema.boolean())(true),
}

export type Placement = schema.Output<typeof(PLACEMENT)>
export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
