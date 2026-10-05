local desktopSettings = require '@lunette-desktop/settings'
local config: desktopSettings.Config = { manager = { visible = false } }
config.manager = { visible = true }
if config.manager then
  config.manager.visible = false
end
local settings: desktopSettings.Settings = desktopSettings.schema.parse(config)
if settings.manager then
  settings.manager.visible = true -- reject.
end
settings.manager = nil -- reject.
config.manager = { visible = 'yes' } -- reject.
return config
