local schema = require '@lunette-plugin/schema'
local descriptors = require '@lunette-plugins/theme/descriptors'

local COLOR = schema.array(schema.number())
local STYLE = schema.object {
  font = schema.optional(descriptors.editableFont),
  windowRadius = schema.optional(schema.number { minimum = 0 }),
  monitorRadius = schema.optional(schema.number { minimum = 0 }),
  borderThickness = schema.optional(schema.number()),
  borderDepth = schema.default(schema.number())(0.001),
  borderColor = schema.optional(COLOR),
  borderHighlightColor = schema.optional(COLOR),
  titleHeight = schema.optional(schema.number()),
  titleMargin = schema.default(schema.number())(0.02),
  titleColor = schema.optional(COLOR),
}
local SCHEMA = schema.object {
  style = schema.default(STYLE)(STYLE.parse {}),
  priority = schema.default(schema.number())(10),
  height = schema.default(schema.number())(0.8),
  aspect = schema.default(schema.number())(16 / 9),
  chrome = schema.default(schema.boolean())(false),
  rendering = schema.default(schema.enum<<'plane' | 'layer'>> { 'plane', 'layer' }) 'plane',
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return SCHEMA
