-- Manager dimensions must fit the shared toolbar and at least one sidebar row.
local schema = require '@lunette-plugin/schema'
local layout = require './private/presentation/toolbar-layout'

local fields = schema.object {
  visible = schema.default(schema.boolean())(false),
  refreshInterval = schema.default(schema.number { minimum = 0.05, maximum = 5 })(0.25),
  view = schema.default(schema.enum<<'entries' | 'graph'>> { 'entries', 'graph' }) 'entries',
  position = schema.default(schema.vector())(vector.pack(0, 1.4, -1.2)),
  width = schema.default(schema.number { minimum = 0.1, maximum = 5 })(1.1),
  height = schema.default(schema.number { minimum = 0.1, maximum = 5 })(0.7),
  pixels = schema.default(schema.number { minimum = layout.minimumWidth, maximum = 2400, integer = true })(1280),
}

export type Config = schema.Input<typeof(fields)>
export type Settings = schema.Output<typeof(fields)>

local descriptor = schema.refine(fields)(function(settings: Settings): ()
  if settings.pixels * settings.height / settings.width < layout.minimumHeight then
    error('manager canvas: logical height must be at least ' .. tostring(layout.minimumHeight) .. ' pixels', 0)
  end
end)

return { schema = descriptor }
