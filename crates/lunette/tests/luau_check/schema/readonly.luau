local schema = require '@lunette-plugin/schema'
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
local function sum(input: { read [number]: number }): number
  local total = 0
  for _, value in input do
    total += value
  end
  return total
end
local function readMap(input: { read [string]: string }): string
  return input.key
end
local metadata = descriptor.inspect()
local unionMetadata = schema.union(schema.number(), schema.string()).inspect()
local function metadataName(value: schema.Metadata): string
  return value.kind
end
local function errorPath(value: schema.Error): string | number
  return value.path[1]
end
sum(settings.list)
readMap(settings.map)
metadataName(metadata)
return {
  descriptor = descriptor,
  settings = settings,
  metadata = metadata,
  unionMetadata = unionMetadata,
  errorPath = errorPath,
  sum = sum,
  readMap = readMap,
}
