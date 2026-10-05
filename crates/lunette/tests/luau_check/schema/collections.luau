local schema = require '@lunette-plugin/schema'
local strings = schema.map(schema.string())
type Strings = schema.Input<typeof(strings)>
local function accepts(value: Strings): Strings
  return value
end
local defaults = schema.default(strings) {}
type DefaultStrings = schema.Input<typeof(defaults)>
local function acceptsDefault(value: DefaultStrings): DefaultStrings
  return value
end
local shape = schema.object { map = defaults }
type Config = schema.Input<typeof(shape)>
local function acceptsObject(value: Config): Config
  return value
end
accepts { key = 'value' }
acceptsDefault { key = 'value' }
acceptsObject { map = { key = 'value' } }
return { accepts = accepts, acceptsDefault = acceptsDefault, acceptsObject = acceptsObject }
