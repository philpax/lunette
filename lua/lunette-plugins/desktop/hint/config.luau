local schema = require '@lunette-plugin/schema'

local positive = schema.refine(schema.number())(function(value: number): ()
  assert(value > 0, 'must be a positive number')
end)
local descriptor = schema.object {
  text = schema.default(schema.string()) 'lunette: no windows yet',
  position = schema.default(schema.vector())(vector.pack(0, 1.5, -1.5)),
  size = schema.default(positive)(0.08),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
