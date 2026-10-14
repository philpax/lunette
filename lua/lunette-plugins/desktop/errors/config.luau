local schema = require '@lunette-plugin/schema'
local descriptors = require '@lunette-contracts/schemas/theme'
local configuration = require '@lunette-plugins/theme/configuration'

local positive = schema.number { positive = true }
local descriptor = schema.object {
  position = schema.default(schema.vector())(vector.pack(0, 1.4, -1.1)),
  width = schema.default(positive)(1.1),
  textHeight = schema.optional(positive),
  columns = schema.default(schema.number { minimum = 1, integer = true })(64),
  lines = schema.default(schema.number { minimum = 1, integer = true })(6),
  background = schema.optional(descriptors.color),
  foreground = schema.optional(descriptors.color),
  font = schema.optional(configuration.editableFont),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
