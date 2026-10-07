local menu = require '@lunette-plugins/desktop/menu'
local config = require '@lunette-plugins/desktop/menu/config'
local geometry = require '@lunette-plugins/desktop/menu/geometry'
local actions = require '@lunette-plugins/desktop/actions'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'

local options: menu.Config = {
  hand = 'right',
  size = 0.15,
  offset = vector.pack(0, 0.1, 0),
  haptic = { strength = 0.4 },
  expanded = { logicalWidth = 480, rowHeight = 48 },
}
local settings: menu.Settings = config.schema.parse(options)
local hand: menu.Hand = settings.hand
local layout: geometry.Layout = geometry.layout(settings, false)
local opening: ui.Bounds = layout.button
local menuDefinition: plugin.Definition<menu.Config> = menu
local actionDefinition: plugin.Definition<actions.Config> = actions
local empty: actions.Config = {}
assert(hand == 'right' and opening.width > 0)

return { menuDefinition, actionDefinition, empty }
