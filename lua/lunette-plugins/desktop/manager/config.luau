-- The manager projects a logical pixel canvas onto a movable flat surface.

local schema = require '@lunette-plugin/schema'

local minimumWidth = 800
-- Eight toolbar rows, the body header, one body row, and the footer must fit on the canvas.
local minimumHeight = 18 + 8 * 30 + 68 + 36 + 64

local fields = schema.object {
  visible = schema.default(schema.boolean())(false),
  position = schema.default(schema.vector())(vector.pack(0, 1.4, -1.2)),
  width = schema.default(schema.number { minimum = 0.1, maximum = 5 })(1.1),
  height = schema.default(schema.number { minimum = 0.1, maximum = 5 })(0.7),
  pixels = schema.default(schema.number { minimum = 800, maximum = 2400, integer = true })(1280),
  toggleKey = schema.default(schema.string { minLength = 1 }) 'f10',
}

export type Config = schema.Input<typeof(fields)>
export type Settings = schema.Output<typeof(fields)>

local descriptor = schema.refine(fields)(function(settings: Settings): ()
  if settings.pixels * settings.height / settings.width < minimumHeight then
    error('manager canvas: logical height must be at least ' .. tostring(minimumHeight) .. ' pixels', 0)
  end
end)

return { schema = descriptor, minimumWidth = minimumWidth, minimumHeight = minimumHeight }
