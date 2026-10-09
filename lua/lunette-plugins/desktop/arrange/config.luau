local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {
  layout = schema.default(schema.string { minLength = 1 }) 'arc',
  tags = schema.default(schema.array(schema.string { minLength = 1 })) {},
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
