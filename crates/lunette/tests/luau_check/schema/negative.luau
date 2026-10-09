local probe = require './positive'
local schema = require '@lunette-plugin/schema'
probe.accepts { count = 'wrong', label = 'sample' } -- reject: number?.
probe.accepts {} -- reject: missing field 'label'.
probe.use { label = 'sample' } -- reject: missing fields.
probe.accepts { label = 'sample', note = 2 } -- reject: string?.
probe.accepts { label = 'sample', tuning = { radius = 'wrong' } } -- reject: number?.
probe.accepts { label = 'sample', list = { 'wrong' } } -- reject: number.
-- Map fields are checked through annotated locals below; the pinned checker misses dictionary function arguments.
probe.accepts {
  label = 'sample',
  callback = function(value: string): number -- reject: (string) -> number.
    return #value
  end,
}
probe.accepts { label = 'sample', direction = { 0, 1, 0 } } -- reject: vector?.
probe.accepts { label = 'sample', mode = 'other' } -- reject: "left" | "right".
probe.configure { label = 'sample', tuning = { radius = 'wrong' } } -- reject: number?.
probe.configure {
  label = 'sample',
  callback = function(value: string): number -- reject: (string) -> number.
    return #value
  end,
}
schema.default(schema.number()) 'wrong' -- reject: number.
schema.default(schema.object { radius = schema.number() }) { radius = 'wrong' } -- reject: number.
schema.literal<<'left'>> 'right' -- reject: "left".
local callback: (number) -> string = schema
  .callback(function(value: number): string
    return tostring(value)
  end)
  .parse(nil)
callback 'wrong' -- reject: number.
local quiet = schema.literal('quiet' :: 'quiet')
type Quiet = schema.Input<typeof(quiet)>
local wrongQuiet: Quiet = 'other' -- reject: "quiet".

local strings = schema.map(schema.string())
type Strings = schema.Input<typeof(strings)>
type StringSettings = schema.Output<typeof(strings)>
local wrongInput: Strings = { key = 1 } -- reject: string.
local wrongOutput: StringSettings = { key = 1 } -- reject: string.
local wrongResult: number = strings.parse({ key = 'value' }).key -- reject: number.
local stringObject = schema.object { map = strings }
type StringObject = schema.Input<typeof(stringObject)>
local wrongNested: StringObject = { map = { key = 1 } } -- reject: string.

-- Inputs are writable and outputs, metadata, and error paths are read-only.
local descriptor = schema.object {
  number = schema.number(),
  list = schema.array(schema.number()),
  map = schema.map(schema.string()),
  nested = schema.object { flag = schema.boolean() },
}
type Config = schema.Input<typeof(descriptor)>
type Settings = schema.Output<typeof(descriptor)>
local config: Config = { number = 1, list = { 1 }, map = { key = 'value' }, nested = { flag = true } }
config.number = 2
config.list[1] = 2
config.map.key = 'edited'
config.nested.flag = false
local settings: Settings = descriptor.parse(config)
settings.number = 2 -- reject: read-only.
settings.nested.flag = false -- reject: read-only.
settings.list[1] = 2 -- reject: read-only.
settings.map.key = 'edited' -- reject: read-only.
local fields = descriptor.inspect().fields
assert(fields)
fields.number = schema.string().inspect() -- reject: read-only.
local alternatives = schema.union(schema.number(), schema.string()).inspect().alternatives
assert(alternatives)
alternatives[1] = schema.string().inspect() -- reject: read-only.
local function mutate(problem: schema.Error): ()
  problem.path[1] = 'changed' -- reject: read-only.
end

return { probe, wrongQuiet, wrongInput, wrongOutput, wrongResult, wrongNested, mutate }
