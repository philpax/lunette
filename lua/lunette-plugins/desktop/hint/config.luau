local schema = require '@lunette-plugin/schema'
local descriptors = require '@lunette-plugins/theme/descriptors'

local positive = schema.number { positive = true }
local descriptor = schema.object {
  text = schema.default(schema.string()) 'lunette: no windows yet',
  position = schema.default(schema.vector())(vector.pack(0, 1.5, -1.5)),
  textHeight = schema.optional(positive),
  foreground = schema.optional(descriptors.color),
  font = schema.optional(descriptors.editableFont),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
