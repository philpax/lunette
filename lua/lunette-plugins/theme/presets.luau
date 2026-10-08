-- Complete immutable presets share the square base's geometry unless a preset explicitly replaces it.

local theme = require '@lunette-contracts/theme'
local descriptors = require './descriptors'

local BASE: theme.Theme = descriptors.theme.parse {
  colors = {
    background = { 0.035, 0.045, 0.065, 1 },
    elevatedBackground = { 0.14, 0.14, 0.17, 0.95 },
    foreground = { 0.94, 0.96, 1, 1 },
    mutedForeground = { 0.65, 0.70, 0.78, 1 },
    control = { 0.13, 0.17, 0.23, 1 },
    hovered = { 0.21, 0.29, 0.39, 1 },
    pressed = { 0.10, 0.35, 0.49, 1 },
    disabled = { 0.25, 0.28, 0.32, 1 },
    border = { 0.44, 0.52, 0.63, 1 },
    focus = { 0.40, 0.82, 1, 1 },
    selection = { 0.20, 0.42, 0.66, 1 },
    error = { 1, 0.38, 0.34, 1 },
    errorBackground = { 0.15, 0.03, 0.03, 0.95 },
    success = { 0.35, 0.85, 0.55, 1 },
    warning = { 1, 0.75, 0.30, 1 },
    ownershipEdge = { 0.45, 0.75, 1, 1 },
    dependencyEdge = { 0.80, 0.60, 1, 1 },
    pointer = { 0.75, 0.80, 0.90, 1 },
    pointerHovered = { 0.40, 0.82, 1, 1 },
  },
  typography = {
    font = { kind = 'default' },
    bodySize = 20,
    smallSize = 16,
    titleHeight = 0.025,
    keyboardLegendHeight = 0.012,
    errorTextHeight = 0.045,
    hintTextHeight = 0.08,
  },
  metrics = {
    padding = 8,
    spacing = 6,
    borderWidth = 2,
    rowHeight = 40,
    titlebarHeight = 0.05,
    titlebarBorderThickness = 0.008,
    keyboardGap = 0.004,
  },
  radii = {
    uiPanel = 0,
    uiControl = 0,
    keyboardBacking = 0,
    keyboardKey = 0,
    titlebar = 0,
    window = 0,
    monitor = 0,
  },
}

local dark: theme.Theme = descriptors.resolve(BASE, {
  radii = {
    uiPanel = 0.008,
    uiControl = 6,
    keyboardBacking = 0.008,
    keyboardKey = 0.002,
    titlebar = 0.008,
    window = 0.008,
    monitor = 0,
  },
})

local light: theme.Theme = descriptors.resolve(dark, {
  colors = {
    background = { 0.93, 0.95, 0.98, 1 },
    elevatedBackground = { 1, 1, 1, 1 },
    foreground = { 0.08, 0.11, 0.17, 1 },
    mutedForeground = { 0.28, 0.33, 0.42, 1 },
    control = { 0.80, 0.85, 0.91, 1 },
    hovered = { 0.65, 0.78, 0.90, 1 },
    pressed = { 0.52, 0.69, 0.83, 1 },
    disabled = { 0.83, 0.85, 0.88, 1 },
    border = { 0.36, 0.43, 0.53, 1 },
    focus = { 0.02, 0.34, 0.66, 1 },
    selection = { 0.59, 0.74, 0.91, 1 },
    error = { 0.72, 0.08, 0.08, 1 },
    errorBackground = { 1, 0.87, 0.86, 1 },
    success = { 0.08, 0.45, 0.24, 1 },
    warning = { 0.58, 0.34, 0.02, 1 },
    ownershipEdge = { 0.07, 0.34, 0.67, 1 },
    dependencyEdge = { 0.48, 0.20, 0.67, 1 },
    pointer = { 0.16, 0.22, 0.31, 1 },
    pointerHovered = { 0.02, 0.38, 0.74, 1 },
  },
})

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
      file = '@lunette-plugins/theme/fonts/SpaceMono-Regular.ttf',
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

return table.freeze { BASE = BASE, dark = dark, light = light, arcade = arcade }
