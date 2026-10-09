local schema = require '@lunette-plugin/schema'
local options = require '@lunette-plugins/laser/options'

local descriptor = schema.object {
  laser = schema.default(options)(options.parse {}),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
