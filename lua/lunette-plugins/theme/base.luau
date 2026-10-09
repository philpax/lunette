-- The square base theme applies while no theme selection is live.

local theme = require '@lunette-contracts/theme'
local descriptors = require './descriptors'

local base: theme.Theme = descriptors.theme.parse {
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

return base
