-- Resolves panel paint over the session theme: the chrome radii, the border, and the title.

local contract = require '@lunette-contracts/theme'
local config = require '../config'

local appearance = {}

-- The resolved paint of every panel: chrome radii, the border, and the title.
export type Style = {
  read windowRadius: number,
  read monitorRadius: number,
  read borderThickness: number,
  read borderDepth: number,
  read borderColor: { read [number]: number },
  read borderHighlightColor: { read [number]: number },
  read titleHeight: number,
  read titleMargin: number,
  read titleColor: { read [number]: number },
}

export type Paint = {
  -- The theme the paint was resolved from; the theme service resolves a new table on each change.
  read theme: contract.Theme,
  read style: Style,
  read font: Font,
}

-- A window's border takes the theme's rule colour, and the accent while highlighted; monitors stay square.
function appearance.prepare(theme: contract.Theme, settings: config.Settings): Paint
  local explicit = settings.style
  local style: Style = table.freeze {
    windowRadius = if explicit.windowRadius == nil then theme.radii.panel else explicit.windowRadius,
    monitorRadius = explicit.monitorRadius,
    borderThickness = explicit.borderThickness,
    borderDepth = explicit.borderDepth,
    borderColor = if explicit.borderColor == nil then theme.colors.line else explicit.borderColor,
    borderHighlightColor = if explicit.borderHighlightColor == nil
      then theme.colors.accent
      else explicit.borderHighlightColor,
    titleHeight = explicit.titleHeight,
    titleMargin = explicit.titleMargin,
    titleColor = if explicit.titleColor == nil then theme.colors.ink else explicit.titleColor,
  }
  return table.freeze { theme = theme, style = style, font = lovr.graphics.getDefaultFont() }
end

return appearance
