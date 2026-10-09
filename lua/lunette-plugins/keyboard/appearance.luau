-- Resolves sparse keyboard appearance over global tokens without owning native resources.

local schema = require '@lunette-plugin/schema'
local keyboard = require '@lunette-contracts/keyboard'
local theme = require '@lunette-contracts/theme'
local descriptors = require '@lunette-plugins/theme/descriptors'

local appearance = {}
local positive = schema.refine(schema.number())(function(value: number): ()
  assert(value > 0, 'must be positive')
end)
local nonnegative = schema.number { minimum = 0 }

local function style<F>(font: F)
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
local editableStyle = style(descriptors.editableFont)
export type EditableStyleConfig = schema.Input<typeof(editableStyle)>
export type EditableStyle = schema.Output<typeof(editableStyle)>

appearance.options = options
appearance.editableStyle = editableStyle

local BASE: keyboard.StyleOptions = options.parse {
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

function appearance.project(value: EditableStyle): keyboard.StyleOptions
  return options.parse {
    font = if value.font then descriptors.projectFont(value.font, 'keyboard style.font') else nil,
    backingRadius = value.backingRadius,
    keyRadius = value.keyRadius,
    keyUnit = value.keyUnit,
    gap = value.gap,
    plateDepth = value.plateDepth,
    legendDepth = value.legendDepth,
    margin = value.margin,
    plateColor = value.plateColor,
    keyColor = value.keyColor,
    heldColor = value.heldColor,
    hoverColor = value.hoverColor,
    legendColor = value.legendColor,
    legendHeight = value.legendHeight,
  }
end

function appearance.resolve(
  global: theme.Theme,
  provider: keyboard.StyleOptions,
  object: keyboard.StyleOptions?
): keyboard.StyleOptions
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
  local configured = options.resolve(provider, tokens, 'keyboard style')
  return options.resolve(object or {}, configured, 'keyboard style')
end

function appearance.scaled(value: keyboard.StyleOptions, font: Font, scale: number): keyboard.Style
  return table.freeze {
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

function appearance.meshChanged(first: keyboard.Style, second: keyboard.Style): boolean
  return first.keyUnit ~= second.keyUnit
    or first.gap ~= second.gap
    or first.margin ~= second.margin
    or first.backingRadius ~= second.backingRadius
    or first.keyRadius ~= second.keyRadius
end

function appearance.geometryChanged(first: keyboard.Style, second: keyboard.Style): boolean
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

return table.freeze(appearance)
