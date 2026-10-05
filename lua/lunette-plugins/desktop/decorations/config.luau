local schema = require '@lunette-plugin/schema'

local positive = schema.refine(schema.number())(function(value: number): ()
  assert(value > 0, 'must be a positive number')
end)
local color = schema.array(schema.number(), { minLength = 4, maxLength = 4 })
local style = schema.object {
  barHeight = schema.default(positive)(0.05),
  margin = schema.default(schema.number())(0.01),
  barColor = schema.default(color) { 0.14, 0.14, 0.17, 0.95 },
  barHighlightColor = schema.default(color) { 0.35, 0.55, 0.95, 0.95 },
  borderThickness = schema.default(schema.number())(0.008),
  borderDepth = schema.default(schema.number())(0.001),
  borderColor = schema.default(color) { 0.14, 0.14, 0.17, 0.95 },
  borderHighlightColor = schema.default(color) { 0.35, 0.55, 0.95, 0.95 },
  titleHeight = schema.default(positive)(0.025),
  titleColor = schema.default(color) { 1, 1, 1, 1 },
}
local descriptor = schema.object {
  style = schema.default(style)(style.parse {}),
}

export type Color = schema.Output<typeof(color)>
export type Style = schema.Output<typeof(style)>
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
