local schema = require '@lunette-plugin/schema'
local descriptors = require '@lunette-contracts/schemas/theme'

local descriptor = schema.object {
  text = schema.default(schema.string()) 'lunette: no windows yet',
  -- The centre of the hint's panel, which faces along +z.
  position = schema.default(schema.vector())(vector.pack(0, 1.5, -1.1)),
  -- The text colour; the toolkit's ink when omitted.
  foreground = schema.optional(descriptors.color),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
