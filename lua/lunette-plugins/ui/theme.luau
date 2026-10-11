-- Sparse appearance layers remain detached; resolved visuals carry the theme service face.
local schema = require '@lunette-plugin/schema'
local ui = require '@lunette-contracts/ui'
local globalTheme = require '@lunette-contracts/theme'
local descriptors = require '@lunette-plugins/theme/descriptors'
local theme = {}

local positive = schema.number { positive = true }
local nonnegative = schema.number { minimum = 0 }
type Fields<F> = {
  background: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  foreground: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  control: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  hovered: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  pressed: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  disabled: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  focus: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  selection: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  error: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  border: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  font: schema.Schema<schema.Input<F>?, schema.Output<F>?>,
  fontSize: schema.Schema<number?, number?>,
  panelRadius: schema.Schema<number?, number?>,
  controlRadius: schema.Schema<number?, number?>,
  padding: schema.Schema<number?, number?>,
  spacing: schema.Schema<number?, number?>,
  borderWidth: schema.Schema<number?, number?>,
  rowHeight: schema.Schema<number?, number?>,
  hapticStrength: schema.Schema<number?, number?>,
  hapticDuration: schema.Schema<number?, number?>,
}
local function fields<F>(font: F): Fields<F>
  return {
    background = schema.optional(descriptors.color),
    foreground = schema.optional(descriptors.color),
    control = schema.optional(descriptors.color),
    hovered = schema.optional(descriptors.color),
    pressed = schema.optional(descriptors.color),
    disabled = schema.optional(descriptors.color),
    focus = schema.optional(descriptors.color),
    selection = schema.optional(descriptors.color),
    error = schema.optional(descriptors.color),
    border = schema.optional(descriptors.color),
    font = schema.optional(font),
    fontSize = schema.optional(positive),
    panelRadius = schema.optional(nonnegative),
    controlRadius = schema.optional(nonnegative),
    padding = schema.optional(nonnegative),
    spacing = schema.optional(nonnegative),
    borderWidth = schema.optional(nonnegative),
    rowHeight = schema.optional(positive),
    hapticStrength = schema.optional(schema.number { minimum = 0, maximum = 1 }),
    hapticDuration = schema.optional(nonnegative),
  }
end
local overrides = schema.object(fields(descriptors.font))
local editable = schema.object(fields(descriptors.editableFont))
export type Spec = schema.Output<typeof(overrides)>

local BASE = {
  background = { 0.035, 0.045, 0.065, 1 },
  foreground = { 0.94, 0.96, 1, 1 },
  control = { 0.13, 0.17, 0.23, 1 },
  hovered = { 0.21, 0.29, 0.39, 1 },
  pressed = { 0.10, 0.35, 0.49, 1 },
  disabled = { 0.25, 0.28, 0.32, 1 },
  focus = { 0.40, 0.82, 1, 1 },
  selection = { 0.20, 0.42, 0.66, 1 },
  error = { 1, 0.38, 0.34, 1 },
  border = { 0.44, 0.52, 0.63, 1 },
  font = { kind = 'default' },
  fontSize = 20,
  panelRadius = 0,
  controlRadius = 0,
  padding = 8,
  spacing = 6,
  borderWidth = 2,
  rowHeight = 40,
  hapticStrength = 0.25,
  hapticDuration = 0.03,
}
theme.editable = editable
theme.DEFAULT = overrides.parse(BASE)

function theme.copyOverrides(value: ui.ThemeOverrides?): ui.ThemeOverrides?
  return if value == nil then nil else overrides.parse(value, 'ui theme overrides')
end

function theme.project(value: unknown): ui.ThemeOverrides
  local parsed = editable.parse(value, 'ui theme configuration')
  local result = table.clone(parsed) :: { [string]: unknown }
  result.font = if parsed.font then descriptors.projectFont(parsed.font) else nil
  return overrides.parse(result, 'ui theme overrides')
end

function theme.inherit(base: ui.ThemeOverrides, value: ui.ThemeOverrides?): ui.ThemeOverrides
  local result = table.clone(base) :: { [string]: unknown }
  for key, field in (value or {}) :: { read [string]: unknown } do
    result[key] = field
  end
  return overrides.parse(result, 'ui theme')
end

function theme.global(value: globalTheme.Theme, radius: number): ui.ThemeOverrides
  local colors, metrics = value.colors, value.metrics
  return theme.inherit(theme.DEFAULT, {
    background = colors.background,
    foreground = colors.foreground,
    control = colors.control,
    hovered = colors.hovered,
    pressed = colors.pressed,
    disabled = colors.disabled,
    focus = colors.focus,
    selection = colors.selection,
    error = colors.error,
    border = colors.border,
    font = value.typography.font,
    fontSize = value.typography.bodySize,
    padding = metrics.padding,
    spacing = metrics.spacing,
    borderWidth = metrics.borderWidth,
    rowHeight = metrics.rowHeight,
    panelRadius = radius,
    controlRadius = value.radii.uiControl,
  })
end

function theme.materialize(spec: ui.ThemeOverrides, font: Font): ui.Theme
  local result = table.clone(theme.inherit(theme.DEFAULT, spec)) :: { [string]: unknown }
  result.font = font
  return table.freeze(result) :: ui.Theme
end

function theme.geometryChanged(first: ui.Theme, second: ui.Theme): boolean
  return first.font ~= second.font
    or first.fontSize ~= second.fontSize
    or first.padding ~= second.padding
    or first.spacing ~= second.spacing
    or first.borderWidth ~= second.borderWidth
    or first.rowHeight ~= second.rowHeight
    or first.panelRadius ~= second.panelRadius
    or first.controlRadius ~= second.controlRadius
end

return theme
