local schema = require '@lunette-plugin/schema'
local descriptor = schema.map(schema.string())
type Config = schema.Input<typeof(descriptor)>
type Settings = schema.Output<typeof(descriptor)>
local wrongInput: Config = { key = 1 }
local wrongOutput: Settings = { key = 1 }
local wrongResult: number = descriptor.parse({ key = 'value' }).key
local object = schema.object { map = descriptor }
type ObjectInput = schema.Input<typeof(object)>
local wrongNested: ObjectInput = { map = { key = 1 } }
return { wrongInput, wrongOutput, wrongResult, wrongNested }
