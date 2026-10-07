local manager = require '@lunette-plugins/desktop/manager'
local config = require '@lunette-plugins/desktop/manager/config'
local options: manager.Config = {}
options.toggleKey = 'f10' -- reject.
options.visible = 'visible' -- reject.
options.position = { 0, 1, -1 } -- reject.
options.pixels = '1200' -- reject.
local settings = config.schema.parse {}
settings.visible = true -- reject.
settings.position = vector.pack(0, 1, -1) -- reject.
settings.pixels = 1200 -- reject.
return options
