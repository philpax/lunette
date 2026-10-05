local plugin = require '@lunette-plugin'
local laser = require '@lunette-plugins/laser'
local laserConfig = require '@lunette-plugins/laser/config'
local keyboard = require '@lunette-plugins/keyboard'
local keyboardConfig = require '@lunette-plugins/keyboard/config'
local panels = require '@lunette-plugins/panels'
local pacing = require '@lunette-plugins/pacing'
local scale = require '@lunette-plugins/scale'
local arc = require '@lunette-plugins/layout/arc'

local laserInput: laser.Config = { style = { length = 2 }, buttons = { { control = 'grip', button = 'right' } } }
local laserOutput: laser.Settings = laserConfig.parse(laserInput)
local keyboardInput: keyboard.Config = {
  rows = { { { action = { kind = 'text', text = '#' }, width = 2 } } },
  layers = { symbols = {} },
  style = { gap = 0.01 },
}
local keyboardOutput: keyboard.Settings = keyboardConfig.parse(keyboardInput)
local panelInput: panels.Config = { shape = {}, style = {}, chrome = true }
local pacingInput: pacing.Config = { tuning = { exemptTypes = { none = true } } }
local scaleInput: scale.Config = { tuning = { reference = 2 } }
local arcInput: arc.Config = { tuning = { center = vector.pack(0, 2, 0) } }

plugin.configure(laser.definition)(laserInput)
plugin.configure(keyboard.definition)(keyboardInput)
plugin.configure(panels.definition)(panelInput)
plugin.configure(pacing.definition)(pacingInput)
plugin.configure(scale.definition)(scaleInput)
plugin.configure(arc.definition)(arcInput)

local readInput: laser.ReadInput = laserOutput.readInput
local onKey: keyboard.OnKey = keyboardOutput.onKey

return { readInput = readInput, onKey = onKey }
