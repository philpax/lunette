local manager = require '@lunette-plugins/desktop/manager'
local config = require '@lunette-plugins/desktop/manager/config'
local desktop = require '@lunette-desktop'
local options: manager.Config =
  { visible = true, position = vector.pack(0, 1.4, -1), width = 1.2, height = 0.8, pixels = 1200 }
options.visible = false
local settings: manager.Settings = config.schema.parse(options)
local visible: boolean = settings.visible
local pixels: number = settings.pixels
local entries = desktop.compose { settings = { manager = options } }
return { visible = visible, pixels = pixels, entries = entries }
