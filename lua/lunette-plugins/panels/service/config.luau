local schema = require '@lunette-plugin/schema'
local color = require '@lunette-contracts/schemas/color'

-- Omitted colours and the window radius follow the toolkit theme.
local STYLE = schema.object {
  windowRadius = schema.optional(schema.number { minimum = 0 }),
  monitorRadius = schema.default(schema.number { minimum = 0 })(0),
  borderThickness = schema.default(schema.number())(0.008),
  borderDepth = schema.default(schema.number())(0.001),
  borderColor = schema.optional(color),
  borderHighlightColor = schema.optional(color),
  titleHeight = schema.default(schema.number())(0.025),
  titleMargin = schema.default(schema.number())(0.02),
  titleColor = schema.optional(color),
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
