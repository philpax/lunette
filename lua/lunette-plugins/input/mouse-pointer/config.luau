local schema = require '@lunette-plugin/schema'
local color = require '@lunette-contracts/schemas/color'

local positive = schema.number { positive = true }
local nonnegative = schema.number { minimum = 0 }

local descriptor = schema.object {
  -- Drives the pointer in a headset session too, where mouse movement turns a cursor ahead of the head. Off by
  -- default, because the desktop window's mouse input then reaches the scene whenever the window is used.
  headset = schema.default(schema.boolean())(false),
  -- Radians the cursor turns per pixel of mouse movement.
  sensitivity = schema.default(positive)(0.002),
  -- The largest angle in radians between the cursor and the head's forward direction. It stays below a right angle, so
  -- the cursor never points behind the head.
  cone = schema.default(schema.number { positive = true, maximum = 1.5 })(0.7),
  -- Logical pixels that one wheel unit scrolls.
  scrollScale = schema.default(nonnegative)(15),
  -- Metres that one wheel unit pushes a carried panel away or pulls it nearer.
  pushScale = schema.default(nonnegative)(0.1),
  -- Metres along the ray where the cursor draws when the ray hits nothing.
  distance = schema.default(positive)(1.5),
  -- The cursor's angular radius in radians, so the cursor keeps its apparent size at any distance.
  cursorAngle = schema.default(positive)(0.004),
  -- Seconds without mouse input after which a headset session withdraws the cursor, so it does not hover whatever
  -- the user looks at; the next mouse input brings it back. The desktop simulator keeps it.
  idleTimeout = schema.default(positive)(3),
  -- The colours default to the toolkit theme's muted ink and accent.
  color = schema.optional(color),
  hoverColor = schema.optional(color),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
