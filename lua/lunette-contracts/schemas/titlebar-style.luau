-- Defines sparse titlebar contract fields without font resources or drawing defaults.

local schema = require '@lunette-plugin/schema'
local theme = require '@lunette-contracts/schemas/theme'

local styles = {}

local positive = schema.number { positive = true }
local nonnegative = schema.number { minimum = 0 }
type Fields<F> = {
  font: schema.Schema<schema.Input<F>?, schema.Output<F>?>,
  cornerRadius: schema.Schema<number?, number?>,
  barHeight: schema.Schema<number?, number?>,
  margin: schema.Schema<number?, number?>,
  barColor: schema.Schema<schema.Input<typeof(theme.color)>?, schema.Output<typeof(theme.color)>?>,
  barHighlightColor: schema.Schema<schema.Input<typeof(theme.color)>?, schema.Output<typeof(theme.color)>?>,
  borderThickness: schema.Schema<number?, number?>,
  borderDepth: schema.Schema<number?, number?>,
  borderColor: schema.Schema<schema.Input<typeof(theme.color)>?, schema.Output<typeof(theme.color)>?>,
  borderHighlightColor: schema.Schema<schema.Input<typeof(theme.color)>?, schema.Output<typeof(theme.color)>?>,
  titleHeight: schema.Schema<number?, number?>,
  titleColor: schema.Schema<schema.Input<typeof(theme.color)>?, schema.Output<typeof(theme.color)>?>,
}

function styles.fields<F>(font: F): Fields<F>
  return {
    font = schema.optional(font),
    cornerRadius = schema.optional(nonnegative),
    barHeight = schema.optional(positive),
    margin = schema.optional(nonnegative),
    barColor = schema.optional(theme.color),
    barHighlightColor = schema.optional(theme.color),
    borderThickness = schema.optional(nonnegative),
    borderDepth = schema.optional(nonnegative),
    borderColor = schema.optional(theme.color),
    borderHighlightColor = schema.optional(theme.color),
    titleHeight = schema.optional(positive),
    titleColor = schema.optional(theme.color),
  }
end

styles.schema = schema.object(styles.fields(theme.font))

return table.freeze(styles)
