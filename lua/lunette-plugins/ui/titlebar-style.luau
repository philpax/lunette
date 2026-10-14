-- Sparse world-space titlebar styles inherit the current public runtime theme.
local ui = require '@lunette-contracts/ui'
local theme = require '@lunette-contracts/theme'
local titlebarStyle = require '@lunette-contracts/schemas/titlebar-style'
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
local overrides = titlebarStyle.schema
styles.schema = overrides
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
