local probe = require './positive'
local schema = require '@lunette-plugin/schema'
probe.accepts { count = 'wrong', label = 'sample' }
probe.accepts {}
probe.use { label = 'sample' }
probe.accepts { label = 'sample', note = 2 }
probe.accepts { label = 'sample', tuning = { radius = 'wrong' } }
probe.accepts { label = 'sample', list = { 'wrong' } }
-- Map assignments are checked in collections_negative; the pinned checker misses dictionary function arguments.
probe.accepts {
  label = 'sample',
  callback = function(value: string): number
    return #value
  end,
}
probe.accepts { label = 'sample', direction = { 0, 1, 0 } }
probe.accepts { label = 'sample', mode = 'other' }
probe.configure { label = 'sample', tuning = { radius = 'wrong' } }
probe.configure {
  label = 'sample',
  callback = function(value: string): number
    return #value
  end,
}
schema.default(schema.number()) 'wrong'
schema.default(schema.object { radius = schema.number() }) { radius = 'wrong' }
schema.literal<<'left'>> 'right'
local callback: (number) -> string = schema
  .callback(function(value: number): string
    return tostring(value)
  end)
  .parse(nil)
callback 'wrong'
local quiet = schema.literal('quiet' :: 'quiet')
type Quiet = schema.Input<typeof(quiet)>
local wrongQuiet: Quiet = 'other'
local _unused = wrongQuiet
return probe
