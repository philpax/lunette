-- Sparse world-space titlebar styles inherit the current public runtime theme.
local schema = require '@lunette-plugin/schema'
local ui = require '@lunette-contracts/ui'
local theme = require '@lunette-contracts/theme'
local descriptors = require '@lunette-plugins/theme/descriptors'
local styles = {}

-- A titlebar style resolved for drawing.
export type Style = {
  read font: Font,
  read cornerRadius: number,
  read barHeight: number,
  read margin: number,
  read barColor: ui.Color,
  read barHighlightColor: ui.Color,
  read borderThickness: number,
  read borderDepth: number,
  read borderColor: ui.Color,
  read borderHighlightColor: ui.Color,
  read titleHeight: number,
  read titleColor: ui.Color,
}
local positive = schema.number { positive = true }
local nonnegative = schema.number { minimum = 0 }
local function fields(font)
  return {
    font = schema.optional(font),
    cornerRadius = schema.optional(nonnegative),
    barHeight = schema.optional(positive),
    margin = schema.optional(nonnegative),
    barColor = schema.optional(descriptors.color),
    barHighlightColor = schema.optional(descriptors.color),
    borderThickness = schema.optional(nonnegative),
    borderDepth = schema.optional(nonnegative),
    borderColor = schema.optional(descriptors.color),
    borderHighlightColor = schema.optional(descriptors.color),
    titleHeight = schema.optional(positive),
    titleColor = schema.optional(descriptors.color),
  }
end
local overrides = schema.object(fields(descriptors.font))
styles.schema = overrides
styles.editable = schema.object(fields(descriptors.editableFont))
styles.DEFAULT = overrides.parse {
  font = { kind = 'default' },
  cornerRadius = 0,
  barHeight = 0.05,
  margin = 0.01,
  barColor = { 0.14, 0.14, 0.17, 0.95 },
  barHighlightColor = { 0.35, 0.55, 0.95, 0.95 },
  borderThickness = 0.008,
  borderDepth = 0.001,
  borderColor = { 0.14, 0.14, 0.17, 0.95 },
  borderHighlightColor = { 0.35, 0.55, 0.95, 0.95 },
  titleHeight = 0.025,
  titleColor = { 1, 1, 1, 1 },
}

function styles.project(value: unknown): ui.TitlebarStyleOverrides
  local parsed = styles.editable.parse(value, 'ui titlebar configuration')
  local result = table.clone(parsed) :: { [string]: unknown }
  result.font = if parsed.font then descriptors.projectFont(parsed.font) else nil
  return overrides.parse(result, 'ui titlebar style')
end

function styles.inherit(base: ui.TitlebarStyleOverrides, layer: ui.TitlebarStyleOverrides?): ui.TitlebarStyleOverrides
  local result = table.clone(base) :: { [string]: unknown }
  for key, value in (layer or {}) :: { read [string]: unknown } do
    result[key] = value
  end
  return overrides.parse(result)
end

function styles.global(value: theme.Theme): ui.TitlebarStyleOverrides
  return styles.inherit(styles.DEFAULT, {
    font = value.typography.font,
    cornerRadius = value.radii.titlebar,
    barHeight = value.metrics.titlebarHeight,
    borderThickness = value.metrics.titlebarBorderThickness,
    titleHeight = value.typography.titleHeight,
    titleColor = value.colors.foreground,
    barColor = value.colors.elevatedBackground,
    barHighlightColor = value.colors.hovered,
    borderColor = value.colors.border,
    borderHighlightColor = value.colors.focus,
  })
end

function styles.materialize(spec: ui.TitlebarStyleOverrides, font: Font): Style
  local result = table.clone(styles.inherit(styles.DEFAULT, spec)) :: { [string]: unknown }
  result.font = font
  return table.freeze(result) :: Style
end

return styles
