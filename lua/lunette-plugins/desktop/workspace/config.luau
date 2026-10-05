local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {
  name = schema.default(schema.string { minLength = 1 }) 'main',
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
