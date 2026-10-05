local schema = require '@lunette-plugin/schema'

local option = schema.custom<<{ read [string]: unknown }>> {
  runtimeType = 'table',
  validate = function(value: unknown): { read [string]: unknown }
    assert(type(value) == 'table', 'layout options are a table')
    for key in value :: { [unknown]: unknown } do
      assert(type(key) == 'string', 'layout option names are strings')
    end
    return value :: { read [string]: unknown }
  end,
}
local options = schema.refine(schema.map(option))(function(value): ()
  for name in value do
    assert(name ~= '', 'layout options are keyed by a non-empty layout name')
  end
end)
local descriptor = schema.object {
  layout = schema.default(schema.string { minLength = 1 }) 'arc',
  options = schema.default(options) {},
  tags = schema.default(schema.array(schema.string { minLength = 1 })) {},
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
