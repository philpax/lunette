-- Resolves panel paint without retaining native font handles in the public style.

local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/panels'
local theme = require '@lunette-contracts/theme'
local descriptors = require '@lunette-plugins/theme/descriptors'
local config = require './config'

local appearance = {}

export type Paint = {
  read revision: number,
  read style: contracts.Style,
  read lease: theme.FontLease,
}

function appearance.prepare(
  broker: theme.Service,
  owner: plugin.Owner,
  settings: config.Settings,
  snapshot: theme.Snapshot
): Paint
  local global, explicit = snapshot.theme, settings.style
  local style: contracts.Style = table.freeze {
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
  local lease = broker:acquireFont(owner, style.font)
  return table.freeze { revision = snapshot.revision, style = style, lease = lease }
end

return appearance
