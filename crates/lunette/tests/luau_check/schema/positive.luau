local schema = require '@lunette-plugin/schema'
local plugin = require '@lunette-plugin'
local callback = function(value: number): string
  return tostring(value)
end
local descriptor = schema.object {
  count = schema.default(schema.number())(1),
  label = schema.string(),
  note = schema.optional(schema.string()),
  tuning = schema.default(schema.object {
    radius = schema.default(schema.number())(2),
  }) { radius = 2 },
  list = schema.default(schema.array(schema.number())) {},
  map = schema.default(schema.map(schema.string())) {},
  callback = schema.default(schema.callback(callback))(callback),
  direction = schema.default(schema.vector())(vector.pack(0, 1, 0)),
  mode = schema.default(schema.enum<<'left' | 'right'>> { 'left', 'right' }) 'left',
  shape = schema.optional(schema.union {
    schema.object { kind = schema.literal<<'dot'>> 'dot' },
    schema.object { kind = schema.literal<<'line'>> 'line', length = schema.number() },
    schema.literal<<'none'>> 'none',
  }),
  enabled = schema.default(schema.boolean())(true),
}
type Config = schema.Input<typeof(descriptor)>
type Settings = schema.Output<typeof(descriptor)>
local config: Config = { label = 'sample', tuning = {} }
local resolved: Settings = descriptor.parse(config)
local function accepts(value: Config): Config
  return value
end
local function use(value: Settings): number
  return value.count + value.tuning.radius
end
local probe = plugin.consumer<<Config, Settings>> {
  name = 'schema-probe',
  schema = descriptor,
  init = function(_context: plugin.Context, value: Settings): ()
    use(value)
  end,
}
local configure = plugin.configure('schema-probe', probe.definition)
configure { label = 'sample', tuning = {}, list = { 1 }, map = { key = 'value' }, mode = 'right' }
local custom = schema.custom {
  runtimeType = 'table',
  validate = function(value: unknown): { read marker: boolean }
    assert(type(value) == 'table')
    return (value :: unknown) :: { read marker: boolean }
  end,
}
local annotated = schema.describe(schema.refine(descriptor)(function(value: Settings): ()
  assert(value.count > 0, 'positive count is required')
end)) { label = 'Probe' }
local overrides = schema.partial(descriptor)
type Overrides = schema.Output<typeof(overrides)>
local sparse: Overrides = overrides.parse {}
local sparseCount: number? = sparse.count
local shaped: Settings = descriptor.parse { label = 'sample', shape = { kind = 'line', length = 1 } }
local result: Settings = annotated.parse(config)
local bound: Settings = descriptor.resolve({ tuning = {} }, result)
local booleanLiteral: false = schema.literal<<false>>(false).parse(false)
local quiet = schema.literal('quiet' :: 'quiet')
type Quiet = schema.Input<typeof(quiet)>
local quietInput: Quiet = 'quiet'
use(bound)
local marker: boolean = custom.parse({ marker = true }).marker
local count: number = schema.default(schema.number())(4).parse(nil)
use(result)
use(resolved)
accepts(config)
local strings = schema.map(schema.string())
local defaultStrings = schema.default(strings) {}
local stringObject = schema.object { map = defaultStrings }
local stringsInput: schema.Input<typeof(strings)> = { key = 'value' }
local defaultStringsInput: schema.Input<typeof(defaultStrings)> = { key = 'value' }
local stringObjectInput: schema.Input<typeof(stringObject)> = { map = { key = 'value' } }
return {
  accepts = accepts,
  use = use,
  configure = configure,
  marker = marker,
  count = count,
  quiet = quietInput,
  sparse = sparseCount,
  shaped = shaped,
  disabled = booleanLiteral,
  strings = { stringsInput, defaultStringsInput, stringObjectInput },
}
