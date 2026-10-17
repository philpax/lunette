local schema = require '@lunette-plugin/schema'

local positive = schema.number { positive = true }
local nonnegative = schema.number { minimum = 0 }

local descriptor = schema.object {
  -- The mouse button that turns the head while it is dragged. The primary button stays with the mouse pointer.
  lookButton = schema.default(schema.enum<<'secondary' | 'middle'>> { 'secondary', 'middle' }) 'secondary',
  -- How far a drag turns the head. At 1 the scene stays under the cursor, as if held; below 1 it turns less.
  lookScale = schema.default(positive)(1),
  -- How quickly the view catches up with a drag, per second. Zero turns the view at once.
  smoothing = schema.default(nonnegative)(0),
  -- Metres per second while moving, while holding shift, and while holding control.
  speed = schema.default(positive)(3),
  sprintSpeed = schema.default(positive)(15),
  walkSpeed = schema.default(positive)(0.5),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
