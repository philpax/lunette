local schema = require '@lunette-plugin/schema'

local positive = schema.number { positive = true }
local placement = schema.object {
  center = schema.default(schema.vector())(vector.pack(0, 1.5, -2)),
  width = schema.default(positive)(2),
  gap = schema.default(schema.number { minimum = 0 })(0.1),
}
local descriptor = schema.object {
  select = schema.default(schema.array(schema.string { minLength = 1 })) {},
  placement = schema.default(placement)(placement.parse {}),
  tags = schema.default(schema.array(schema.string { minLength = 1 })) {},
  -- Ids of monitors not mirrored. Closing a mirror, or turning it off in the wrist menu's Monitors group, adds its
  -- monitor, and turning it on removes it, so mirrors return at the next start as they were left.
  hidden = schema.default(schema.array(schema.string { minLength = 1 })) {},
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
