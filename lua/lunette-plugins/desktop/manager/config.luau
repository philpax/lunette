-- Manager dimensions must fit the shared toolbar and at least one sidebar row.
local schema = require '@lunette-plugin/schema'
local layout = require './toolbar-layout'

local fields = schema.object {
  visible = schema.default(schema.boolean())(false),
  refreshInterval = schema.default(schema.number { minimum = 0.05, maximum = 5 })(0.25),
  view = schema.default(schema.union(schema.literal<<'entries'>> 'entries', schema.literal<<'graph'>> 'graph')) 'entries',
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

local function checkRemovedFields(value: unknown, name: string?): ()
  if type(value) == 'table' and rawget(value :: { [string]: unknown }, 'toggleKey') ~= nil then
    local prefix = if name then 'plugin ' .. name .. ': ' else ''
    error(prefix .. 'toggleKey is removed; open Plugins from the session menu', 0)
  end
end

-- Keep the descriptor token and witnesses for configured consumers and schema inspection.
local checked = table.clone((descriptor :: unknown) :: { [string]: unknown })
checked.parse = function(value: unknown, name: string?): Settings
  checkRemovedFields(value, name)
  return descriptor.parse(value, name)
end
checked.resolve = function(value: unknown, base: Settings, name: string?): Settings
  checkRemovedFields(value, name)
  checkRemovedFields(base, name)
  return descriptor.resolve(value, base, name)
end

return {
  schema = (table.freeze(checked) :: unknown) :: typeof(descriptor),
  minimumWidth = layout.minimumWidth,
  minimumHeight = layout.minimumHeight,
}
