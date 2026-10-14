-- Resolves sparse keyboard appearance over global tokens without owning native resources.

local schema = require '@lunette-plugin/schema'
local theme = require '@lunette-contracts/theme'
local descriptors = require '@lunette-contracts/schemas/theme'
local configuration = require '@lunette-plugins/theme/configuration'
local hooks = require './hooks'

local appearance = {}

export type Style = hooks.Style

local positive = schema.number { positive = true }
local nonnegative = schema.number { minimum = 0 }

type StyleShape<F> = {
  font: schema.Schema<schema.Input<F>?, schema.Output<F>?>,
  backingRadius: schema.Schema<number?, number?>,
  keyRadius: schema.Schema<number?, number?>,
  keyUnit: schema.Schema<number?, number?>,
  gap: schema.Schema<number?, number?>,
  plateDepth: schema.Schema<number?, number?>,
  legendDepth: schema.Schema<number?, number?>,
  margin: schema.Schema<number?, number?>,
  plateColor: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  keyColor: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  heldColor: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  hoverColor: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  legendColor: schema.Schema<schema.Input<typeof(descriptors.color)>?, schema.Output<typeof(descriptors.color)>?>,
  legendHeight: schema.Schema<number?, number?>,
}
local function style<F>(font: F): schema.Schema<schema.ObjectInput<StyleShape<F>>, schema.ObjectOutput<StyleShape<F>>>
  return schema.object {
    font = schema.optional(font),
    backingRadius = schema.optional(nonnegative),
    keyRadius = schema.optional(nonnegative),
    keyUnit = schema.optional(positive),
    gap = schema.optional(nonnegative),
    plateDepth = schema.optional(nonnegative),
    legendDepth = schema.optional(nonnegative),
    margin = schema.optional(nonnegative),
    plateColor = schema.optional(descriptors.color),
    keyColor = schema.optional(descriptors.color),
    heldColor = schema.optional(descriptors.color),
    hoverColor = schema.optional(descriptors.color),
    legendColor = schema.optional(descriptors.color),
    legendHeight = schema.optional(positive),
  }
end

local options = style(descriptors.font)
local editableStyle = style(configuration.editableFont)
export type EditableStyleConfig = schema.Input<typeof(editableStyle)>
export type EditableStyle = schema.Output<typeof(editableStyle)>
-- A sparse style whose omitted fields fall through to the theme.
export type Options = schema.Output<typeof(options)>

appearance.editableStyle = editableStyle

local BASE: Options = options.parse {
  font = { kind = 'default' },
  backingRadius = 0,
  keyRadius = 0,
  keyUnit = 0.028,
  gap = 0.004,
  plateDepth = 0.002,
  legendDepth = 0.001,
  margin = 0.008,
  plateColor = { 0.1, 0.1, 0.13, 0.92 },
  keyColor = { 0.2, 0.2, 0.24, 1 },
  heldColor = { 0.35, 0.55, 0.95, 1 },
  hoverColor = { 0.4, 0.42, 0.5, 1 },
  legendColor = { 1, 1, 1, 1 },
  legendHeight = 0.012,
}

function appearance.project(value: EditableStyle): Options
  local projected: { [string]: unknown } = table.clone(value) :: any
  projected.font = if value.font then configuration.projectFont(value.font, 'keyboard style.font') else nil
  return options.parse(projected)
end

function appearance.resolve(global: theme.Theme, provider: Options): Options
  local tokens = options.resolve({
    font = global.typography.font,
    backingRadius = global.radii.keyboardBacking,
    keyRadius = global.radii.keyboardKey,
    gap = global.metrics.keyboardGap,
    plateColor = global.colors.background,
    keyColor = global.colors.control,
    heldColor = global.colors.pressed,
    hoverColor = global.colors.hovered,
    legendColor = global.colors.foreground,
    legendHeight = global.typography.keyboardLegendHeight,
  }, BASE, 'keyboard style')
  return options.resolve(provider, tokens, 'keyboard style')
end

function appearance.scaled(value: Options, font: Font, scale: number): Style
  return {
    font = font,
    backingRadius = (value.backingRadius :: number) * scale,
    keyRadius = (value.keyRadius :: number) * scale,
    keyUnit = (value.keyUnit :: number) * scale,
    gap = (value.gap :: number) * scale,
    margin = (value.margin :: number) * scale,
    plateDepth = (value.plateDepth :: number) * scale,
    legendDepth = (value.legendDepth :: number) * scale,
    legendHeight = (value.legendHeight :: number) * scale,
    plateColor = value.plateColor :: theme.Color,
    keyColor = value.keyColor :: theme.Color,
    heldColor = value.heldColor :: theme.Color,
    hoverColor = value.hoverColor :: theme.Color,
    legendColor = value.legendColor :: theme.Color,
  }
end

function appearance.meshChanged(first: Style, second: Style): boolean
  return first.keyUnit ~= second.keyUnit
    or first.gap ~= second.gap
    or first.margin ~= second.margin
    or first.backingRadius ~= second.backingRadius
    or first.keyRadius ~= second.keyRadius
end

function appearance.geometryChanged(first: Style, second: Style): boolean
  return first.font ~= second.font
    or first.keyUnit ~= second.keyUnit
    or first.gap ~= second.gap
    or first.margin ~= second.margin
    or first.plateDepth ~= second.plateDepth
    or first.legendDepth ~= second.legendDepth
    or first.legendHeight ~= second.legendHeight
    or first.backingRadius ~= second.backingRadius
    or first.keyRadius ~= second.keyRadius
end

return appearance
