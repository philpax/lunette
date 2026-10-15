-- Validates stable theme contract values and resolves detached override layers.

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
local overrides = schema.object {
  colors = schema.optional(schema.partial(colors)),
  typography = schema.optional(schema.partial(typography)),
  metrics = schema.optional(schema.partial(metrics)),
  radii = schema.optional(schema.partial(radii)),
}

descriptors.color = color
descriptors.font = font
descriptors.colors = colors
descriptors.typography = typography
descriptors.metrics = metrics
descriptors.radii = radii
descriptors.theme = themeDescriptor
descriptors.overrides = overrides

function descriptors.resolve(base: theme.Theme, value: theme.ThemeOverrides?): theme.Theme
  local validated = themeDescriptor.parse(base, 'theme')
  local layer = overrides.parse(if value == nil then {} else value, 'theme overrides')
  return themeDescriptor.resolve(layer, validated, 'theme')
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
