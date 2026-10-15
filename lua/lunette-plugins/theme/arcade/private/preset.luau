-- Arcade replaces every theme group: a saturated palette, the bundled Space Mono face, and larger metrics and radii.

local theme = require '@lunette-contracts/theme'
local descriptors = require '@lunette-contracts/schemas/theme'

local arcade: theme.Theme = descriptors.theme.parse {
  colors = {
    background = { 0.07, 0.025, 0.24, 1 },
    elevatedBackground = { 0.16, 0.055, 0.40, 1 },
    foreground = { 1, 0.94, 0.16, 1 },
    mutedForeground = { 0.78, 0.70, 0.98, 1 },
    control = { 0.23, 0.09, 0.52, 1 },
    hovered = { 0, 0.42, 0.48, 1 },
    pressed = { 0.60, 0.22, 0.02, 1 },
    disabled = { 0.22, 0.17, 0.36, 1 },
    border = { 0.55, 0.26, 0.95, 1 },
    focus = { 0, 1, 1, 1 },
    selection = { 0.48, 0.10, 0.75, 1 },
    error = { 1, 0.22, 0.40, 1 },
    errorBackground = { 0.30, 0.01, 0.14, 1 },
    success = { 0.20, 1, 0.42, 1 },
    warning = { 1, 0.62, 0.04, 1 },
    ownershipEdge = { 0.10, 0.65, 1, 1 },
    dependencyEdge = { 1, 0.18, 0.85, 1 },
    pointer = { 0.85, 1, 0.20, 1 },
    pointerHovered = { 0.25, 1, 0.82, 1 },
  },
  typography = {
    font = {
      kind = 'file',
      file = '@lunette-plugins/theme/arcade/fonts/SpaceMono-Regular.ttf',
      size = 32,
      spread = 4,
    },
    bodySize = 22,
    smallSize = 18,
    titleHeight = 0.030,
    keyboardLegendHeight = 0.014,
    errorTextHeight = 0.050,
    hintTextHeight = 0.090,
  },
  metrics = {
    padding = 12,
    spacing = 10,
    borderWidth = 3,
    rowHeight = 46,
    titlebarHeight = 0.065,
    titlebarBorderThickness = 0.004,
    keyboardGap = 0.006,
  },
  radii = {
    uiPanel = 0.016,
    uiControl = 12,
    keyboardBacking = 0.018,
    keyboardKey = 0.005,
    titlebar = 0.016,
    window = 0.016,
    monitor = 0.012,
  },
}

return arcade
