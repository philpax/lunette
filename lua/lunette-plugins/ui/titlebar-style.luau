-- One style describes the shared world-space titlebar and its panel border.
local schema = require '@lunette-plugin/schema'

local positive = schema.refine(schema.number())(function(value: number): ()
  assert(value > 0, 'must be a positive number')
end)
local nonnegative = schema.number { minimum = 0 }
local color = schema.array(schema.number(), { minLength = 4, maxLength = 4 })
local descriptor = schema.object {
  barHeight = schema.default(positive)(0.05),
  margin = schema.default(nonnegative)(0.01),
  barColor = schema.default(color) { 0.14, 0.14, 0.17, 0.95 },
  barHighlightColor = schema.default(color) { 0.35, 0.55, 0.95, 0.95 },
  borderThickness = schema.default(nonnegative)(0.008),
  borderDepth = schema.default(nonnegative)(0.001),
  borderColor = schema.default(color) { 0.14, 0.14, 0.17, 0.95 },
  borderHighlightColor = schema.default(color) { 0.35, 0.55, 0.95, 0.95 },
  titleHeight = schema.default(positive)(0.025),
  titleColor = schema.default(color) { 1, 1, 1, 1 },
}

local overrides = schema.object {
  barHeight = schema.optional(positive),
  margin = schema.optional(nonnegative),
  barColor = schema.optional(color),
  barHighlightColor = schema.optional(color),
  borderThickness = schema.optional(nonnegative),
  borderDepth = schema.optional(nonnegative),
  borderColor = schema.optional(color),
  borderHighlightColor = schema.optional(color),
  titleHeight = schema.optional(positive),
  titleColor = schema.optional(color),
}

return { schema = descriptor, overrides = overrides, DEFAULT = descriptor.parse {} }
