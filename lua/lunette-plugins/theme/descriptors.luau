-- Pure descriptors validate runtime themes and project editable font settings into strict font specifications.

local schema = require '@lunette-plugin/schema'
local theme = require '@lunette-contracts/theme'

local descriptors = {}

local positive = schema.number { positive = true }
local nonnegative = schema.number { minimum = 0 }
local color = schema.array(schema.number { minimum = 0, maximum = 1 }, { minLength = 4, maxLength = 4 })

local font = schema.union {
  schema.object { kind = schema.literal<<'default'>> 'default' },
  schema.object {
    kind = schema.literal<<'file'>> 'file',
    file = schema.string { minLength = 1 },
    size = positive,
    spread = positive,
  },
}
local editableFontFields = schema.object {
  kind = schema.default(schema.enum<<'default' | 'file'>> { 'default', 'file' }) 'default',
  file = schema.optional(schema.string { minLength = 1 }),
  size = schema.optional(positive),
  spread = schema.optional(positive),
}
export type EditableFontConfig = schema.Input<typeof(editableFontFields)>
export type EditableFont = schema.Output<typeof(editableFontFields)>
local editableFont = schema.refine(editableFontFields)(function(value: EditableFont): ()
  if value.kind == 'default' then
    assert(
      value.file == nil and value.size == nil and value.spread == nil,
      'default fonts have no file, size, or spread'
    )
  else
    assert(value.file ~= nil, 'file fonts require a nonempty file')
  end
end)

local colors = schema.object {
  background = color,
  elevatedBackground = color,
  foreground = color,
  mutedForeground = color,
  control = color,
  hovered = color,
  pressed = color,
  disabled = color,
  border = color,
  focus = color,
  selection = color,
  error = color,
  errorBackground = color,
  success = color,
  warning = color,
  ownershipEdge = color,
  dependencyEdge = color,
  pointer = color,
  pointerHovered = color,
}
local typography = schema.object {
  font = font,
  bodySize = positive,
  smallSize = positive,
  titleHeight = positive,
  keyboardLegendHeight = positive,
  errorTextHeight = positive,
  hintTextHeight = positive,
}
local metrics = schema.object {
  padding = nonnegative,
  spacing = nonnegative,
  borderWidth = nonnegative,
  rowHeight = positive,
  titlebarHeight = positive,
  titlebarBorderThickness = nonnegative,
  keyboardGap = nonnegative,
}
local radii = schema.object {
  uiPanel = nonnegative,
  uiControl = nonnegative,
  keyboardBacking = nonnegative,
  keyboardKey = nonnegative,
  titlebar = nonnegative,
  window = nonnegative,
  monitor = nonnegative,
}
local themeDescriptor = schema.object {
  colors = colors,
  typography = typography,
  metrics = metrics,
  radii = radii,
}

local colorOverrides = schema.partial(colors)
local typographyOverrides = schema.partial(typography)
local metricOverrides = schema.partial(metrics)
local radiusOverrides = schema.partial(radii)
local overrides = schema.object {
  colors = schema.optional(colorOverrides),
  typography = schema.optional(typographyOverrides),
  metrics = schema.optional(metricOverrides),
  radii = schema.optional(radiusOverrides),
}
local editableTypography = schema.object {
  font = schema.optional(editableFont),
  bodySize = schema.optional(positive),
  smallSize = schema.optional(positive),
  titleHeight = schema.optional(positive),
  keyboardLegendHeight = schema.optional(positive),
  errorTextHeight = schema.optional(positive),
  hintTextHeight = schema.optional(positive),
}
local editableOverrides = schema.object {
  colors = schema.optional(colorOverrides),
  typography = schema.optional(editableTypography),
  metrics = schema.optional(metricOverrides),
  radii = schema.optional(radiusOverrides),
}
export type EditableOverridesConfig = schema.Input<typeof(editableOverrides)>
export type EditableOverrides = schema.Output<typeof(editableOverrides)>

descriptors.color = color
descriptors.font = font
descriptors.editableFont = editableFont
descriptors.colors = colors
descriptors.typography = typography
descriptors.metrics = metrics
descriptors.radii = radii
descriptors.theme = themeDescriptor
descriptors.overrides = overrides
descriptors.editableOverrides = editableOverrides

function descriptors.resolve(base: theme.Theme, value: theme.ThemeOverrides?): theme.Theme
  local validated = themeDescriptor.parse(base, 'theme')
  local layer = overrides.parse(if value == nil then {} else value, 'theme overrides')
  return themeDescriptor.resolve(layer, validated, 'theme')
end

function descriptors.projectFont(value: unknown, label: string?): theme.FontSpec
  local parsed = editableFont.parse(value, label or 'theme font')
  if parsed.kind == 'default' then
    return font.parse({ kind = 'default' }, label or 'theme font')
  end
  return font.parse({
    kind = 'file',
    file = parsed.file,
    size = parsed.size or 32,
    spread = parsed.spread or 4,
  }, label or 'theme font')
end

function descriptors.projectOverrides(value: unknown, label: string?): theme.ThemeOverrides
  local parsed = editableOverrides.parse(value, label or 'theme overrides')
  local text = parsed.typography
  return overrides.parse({
    colors = parsed.colors,
    typography = if text
      then {
        font = if text.font then descriptors.projectFont(text.font, label) else nil,
        bodySize = text.bodySize,
        smallSize = text.smallSize,
        titleHeight = text.titleHeight,
        keyboardLegendHeight = text.keyboardLegendHeight,
        errorTextHeight = text.errorTextHeight,
        hintTextHeight = text.hintTextHeight,
      }
      else nil,
    metrics = parsed.metrics,
    radii = parsed.radii,
  }, label or 'theme overrides')
end

function descriptors.fontKey(spec: theme.FontSpec): string
  local parsed = font.parse(spec, 'theme font')
  if parsed.kind == 'default' then
    return 'default'
  end
  return string.format('file:%d:%s:%.17g:%.17g', #parsed.file, parsed.file, parsed.size, parsed.spread)
end

local equalValue: (unknown, unknown) -> boolean

function descriptors.equal<T>(first: T, second: T): boolean
  return equalValue(first, second)
end

equalValue = function(first: unknown, second: unknown): boolean
  if type(first) ~= 'table' or type(second) ~= 'table' then
    return first == second
  end
  local left = first :: { read [unknown]: unknown }
  local right = second :: { read [unknown]: unknown }
  for key, value in left do
    if not equalValue(value, right[key]) then
      return false
    end
  end
  for key in right do
    if left[key] == nil then
      return false
    end
  end
  return true
end

return table.freeze(descriptors)
