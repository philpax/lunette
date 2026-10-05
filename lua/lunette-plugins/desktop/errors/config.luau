local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {
  position = schema.default(schema.vector())(vector.pack(0, 1.4, -1.1)),
  width = schema.default(schema.number())(1.1),
  textHeight = schema.default(schema.number())(0.045),
  columns = schema.default(schema.number { minimum = 1, integer = true })(64),
  lines = schema.default(schema.number { minimum = 1, integer = true })(6),
  background = schema.default(schema.array(schema.number(), { minLength = 4, maxLength = 4 })) { 0.15, 0.03, 0.03, 0.85 },
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
