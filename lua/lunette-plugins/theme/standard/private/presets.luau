-- Dark and Light share the rounded geometry and default face and differ only in palette.

local theme = require '@lunette-contracts/theme'
local base = require '@lunette-plugins/theme/base'
local descriptors = require '@lunette-contracts/schemas/theme'

local dark: theme.Theme = descriptors.resolve(base, {
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

return table.freeze { dark = dark, light = light }
