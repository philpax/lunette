-- Resolves sparse keyboard appearance over the session theme without owning native resources.

local schema = require '@lunette-plugin/schema'
local theme = require '@lunette-contracts/theme'
local color = require '@lunette-contracts/schemas/color'
local hooks = require '../hooks'

local appearance = {}

export type Style = hooks.Style

local positive = schema.number { positive = true }
local nonnegative = schema.number { minimum = 0 }

local options = schema.object {
  backingRadius = schema.optional(nonnegative),
  keyRadius = schema.optional(nonnegative),
  keyUnit = schema.optional(positive),
  gap = schema.optional(nonnegative),
  plateDepth = schema.optional(nonnegative),
  legendDepth = schema.optional(nonnegative),
  margin = schema.optional(nonnegative),
  plateColor = schema.optional(color),
  keyColor = schema.optional(color),
  heldColor = schema.optional(color),
  hoverColor = schema.optional(color),
  legendColor = schema.optional(color),
  legendHeight = schema.optional(positive),
}
export type EditableStyleConfig = schema.Input<typeof(options)>
export type EditableStyle = schema.Output<typeof(options)>
-- A sparse style whose omitted fields fall through to the session theme.
export type Options = schema.Output<typeof(options)>

appearance.editableStyle = options

local BASE: Options = options.parse {
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
  return options.parse(value)
end

-- The board takes the theme's panel surface for its plate, raised keys with the accent while held, and the theme's
-- ink for legends.
function appearance.resolve(global: theme.Theme, provider: Options): Options
  local colors = global.colors
  local tokens = options.resolve({
    backingRadius = global.radii.panel,
    keyRadius = global.radii.control,
    plateColor = colors.surface,
    keyColor = colors.raised,
    heldColor = colors.accent,
    hoverColor = colors.hover,
    legendColor = colors.ink,
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
