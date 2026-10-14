-- Resolves panel paint; the public style names the font by specification.

local theme = require '@lunette-contracts/theme'
local descriptors = require '@lunette-plugins/theme/configuration'
local config = require './config'

local appearance = {}

-- The resolved paint of every panel: chrome radii, the border, and the title.
export type Style = {
  read font: theme.FontSpec,
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
  read revision: number,
  read style: Style,
  read font: Font,
}

function appearance.prepare(broker: theme.Service, settings: config.Settings, snapshot: theme.Snapshot): Paint
  local global, explicit = snapshot.theme, settings.style
  local style: Style = table.freeze {
    font = if explicit.font
      then descriptors.projectFont(explicit.font, 'panels style font')
      else global.typography.font,
    windowRadius = if explicit.windowRadius == nil then global.radii.window else explicit.windowRadius,
    monitorRadius = if explicit.monitorRadius == nil then global.radii.monitor else explicit.monitorRadius,
    borderThickness = if explicit.borderThickness == nil
      then global.metrics.titlebarBorderThickness
      else explicit.borderThickness,
    borderDepth = explicit.borderDepth,
    borderColor = if explicit.borderColor == nil then global.colors.border else explicit.borderColor,
    borderHighlightColor = if explicit.borderHighlightColor == nil
      then global.colors.focus
      else explicit.borderHighlightColor,
    titleHeight = if explicit.titleHeight == nil then global.typography.titleHeight else explicit.titleHeight,
    titleMargin = explicit.titleMargin,
    titleColor = if explicit.titleColor == nil then global.colors.foreground else explicit.titleColor,
  }
  return table.freeze { revision = snapshot.revision, style = style, font = broker:font(style.font) }
end

return appearance
