local menu = require '@lunette-plugins/desktop/menu'
local config = require '@lunette-plugins/desktop/menu/config'
local geometry = require '@lunette-plugins/desktop/menu/geometry'

local badHand: menu.Config = { hand = 'middle' } -- reject.
local badOffset: menu.Config = { offset = { 0, 0, 0 } } -- reject.
local badHaptic: menu.Config = { haptic = { strength = 'strong' } } -- reject.
local badLogicalSize: menu.Config = { expanded = { logicalWidth = 'wide' } } -- reject.
local settings: menu.Settings = config.schema.parse {}
settings.size = 0.2 -- reject.
settings.haptic.strength = 0.1 -- reject.
local layout = geometry.layout(settings, false)
layout.button.width = 1 -- reject.

return { badHand, badOffset, badHaptic, badLogicalSize }
