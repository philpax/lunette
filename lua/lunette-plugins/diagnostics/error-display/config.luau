local schema = require '@lunette-plugin/schema'

local positive = schema.number { positive = true }
local count = schema.number { minimum = 1, integer = true }
local descriptor = schema.object {
  -- The centre of the overlay panel, which faces along +z.
  position = schema.default(schema.vector())(vector.pack(0, 1.45, -0.85)),
  -- The panel's width in metres; its height follows the reports shown.
  width = schema.default(positive)(0.46),
  -- Lines of a report's message, and of its traceback, before the rest is elided.
  lines = schema.default(count)(6),
  -- Distinct reports the history keeps; the least recent leaves first.
  history = schema.default(count)(50),
  -- Reports on one page of the overlay.
  page = schema.default(count)(3),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
