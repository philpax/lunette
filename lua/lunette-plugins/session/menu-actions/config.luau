local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {
  -- Saved by the actions: whether Hide panels was on, so a reload or a restart keeps the panels hidden.
  panelsHidden = schema.default(schema.boolean())(false),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
