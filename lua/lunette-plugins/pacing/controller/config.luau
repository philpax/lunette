local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {
  pauseMonitors = schema.default(schema.boolean())(true),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
