-- Manager dimensions are metres, and leave room for the toolbar, the sidebar, and at least one list row.
local schema = require '@lunette-plugin/schema'

local fields = schema.object {
  visible = schema.default(schema.boolean())(false),
  refreshInterval = schema.default(schema.number { minimum = 0.05, maximum = 5 })(0.25),
  view = schema.default(schema.enum<<'entries' | 'graph'>> { 'entries', 'graph' }) 'entries',
  position = schema.default(schema.vector())(vector.pack(0, 1.4, -1.2)),
  width = schema.default(schema.number { minimum = 0.6, maximum = 5 })(1.1),
  height = schema.default(schema.number { minimum = 0.4, maximum = 5 })(0.7),
}

export type Config = schema.Input<typeof(fields)>
export type Settings = schema.Output<typeof(fields)>

return { schema = fields }
