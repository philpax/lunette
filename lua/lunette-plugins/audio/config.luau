local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
