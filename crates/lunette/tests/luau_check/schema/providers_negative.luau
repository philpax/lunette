local plugin = require '@lunette-plugin'
local laser = require '@lunette-plugins/laser'
local keyboard = require '@lunette-plugins/keyboard'
local panels = require '@lunette-plugins/panels'
local pacing = require '@lunette-plugins/pacing'
local scale = require '@lunette-plugins/scale'
local arc = require '@lunette-plugins/layout/arc'

local laserLength: laser.Config = { style = { length = 'long' } }
local laserButton: laser.Config = { buttons = { { control = 'pinch', button = 'left' } } }
local keyboardAction: keyboard.Config = { rows = { { { action = { kind = 'warp' } } } } }
local panelChrome: panels.Config = { chrome = 'yes' }
local pacingRate: pacing.Config = { tuning = { background = 'fast' } }
local scaleDistance: scale.Config = { tuning = { reference = false } }
local arcCenter: arc.Config = { tuning = { center = { 0, 1, 0 } } }
local laserSettings: laser.Settings = {}
local keyboardSettings: keyboard.Settings = {}

plugin.configure(laser.definition) {
  draw = function(_value: number): number
    return 0
  end,
}
plugin.configure(keyboard.definition) {
  onKey = function(_value: number): number
    return 0
  end,
}

return {
  laserLength,
  laserButton,
  keyboardAction,
  panelChrome,
  pacingRate,
  scaleDistance,
  arcCenter,
  laserSettings,
  keyboardSettings,
}
