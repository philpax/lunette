local schema = require '@lunette-plugin/schema'
local descriptors = require '@lunette-contracts/schemas/theme'
local configuration = require '@lunette-plugins/theme/configuration'

local STYLE = schema.object {
  font = schema.optional(configuration.editableFont),
  windowRadius = schema.optional(schema.number { minimum = 0 }),
  monitorRadius = schema.optional(schema.number { minimum = 0 }),
  borderThickness = schema.optional(schema.number()),
  borderDepth = schema.default(schema.number())(0.001),
  borderColor = schema.optional(descriptors.color),
  borderHighlightColor = schema.optional(descriptors.color),
  titleHeight = schema.optional(schema.number()),
  titleMargin = schema.default(schema.number())(0.02),
  titleColor = schema.optional(descriptors.color),
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

return { schema = SCHEMA }
