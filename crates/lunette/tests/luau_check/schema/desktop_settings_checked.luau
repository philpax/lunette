-- Desktop shorthand inputs remain writable; resolved settings reject writes at each declared boundary.
local schema = require '@lunette-plugin/schema'
local desktopSettings = require '@lunette-desktop/settings'

local config: desktopSettings.Config = {
  menu = { hand = 'right', expanded = { rowHeight = 40 } },
  decorations = { style = { barColor = { 0, 0, 0, 1 } } },
  arrange = { layout = 'grid' },
  persistence = { file = 'desktop.state' },
  wristKeyboard = { placement = { distance = 0.45 } },
  rules = { rules = {} },
  monitors = { select = { 'DP-1' }, placement = { gap = 0.1 } },
  hint = { text = 'Waiting for windows' },
  errors = { columns = 64 },
  pointing = { laser = { tuning = { reach = 10 }, style = { color = { 1, 1, 1, 1 } } } },
  pacing = { pauseMonitors = true },
  workspace = { name = 'main' },
  adoption = { tags = { 'main' } },
}
local exportedConfig: desktopSettings.Config = config
exportedConfig.workspace = { name = 'main' }
if config.menu then
  config.menu.hand = 'left'
  config.menu.size = 0.12
  if config.menu.expanded then
    config.menu.expanded.rowHeight = 42
  end
end
if config.decorations and config.decorations.style and config.decorations.style.barColor then
  config.decorations.style.barColor[1] = 0.2
end
if config.arrange then
  config.arrange.layout = 'arc'
end
if config.persistence then
  config.persistence.file = 'edited.state'
end
if config.wristKeyboard and config.wristKeyboard.placement then
  config.wristKeyboard.placement.distance = 0.55
end
if config.rules and config.rules.rules then
  config.rules.rules[1] = { match = { appId = 'sample' }, properties = { width = 2 } }
end
if config.monitors then
  if config.monitors.select then
    config.monitors.select[1] = 'DP-2'
  end
  if config.monitors.placement then
    config.monitors.placement.gap = 0.2
  end
end
if config.hint then
  config.hint.text = 'No windows'
end
if config.errors then
  config.errors.columns = 80
end
if config.pointing and config.pointing.laser then
  if config.pointing.laser.tuning then
    config.pointing.laser.tuning.reach = 12
  end
  if config.pointing.laser.style and config.pointing.laser.style.color then
    config.pointing.laser.style.color[1] = 0.5
  end
end
if config.pacing then
  config.pacing.pauseMonitors = false
end
if config.workspace then
  config.workspace.name = 'work'
end
if config.adoption and config.adoption.tags then
  config.adoption.tags[1] = 'work'
end

local settings: desktopSettings.Settings = desktopSettings.schema.parse(config)
local projected: desktopSettings.Settings = settings
local metadata: schema.Metadata = desktopSettings.schema.inspect()
if settings.menu then
  settings.menu.hand = 'left' -- reject.
  settings.menu.expanded.rowHeight = 40 -- reject.
end
if settings.decorations then
  settings.decorations.style.barColor[1] = 0.2 -- reject.
end
if settings.rules then
  settings.rules.rules[1] = { properties = { width = 3 } } -- reject.
end
if settings.wristKeyboard then
  settings.wristKeyboard.placement.distance = 0.65 -- reject.
end
if settings.pointing and settings.pointing.laser.style and settings.pointing.laser.style.color then
  settings.pointing.laser.style.color[1] = 0.3 -- reject.
end
if settings.pacing then
  local paused: boolean = settings.pacing.pauseMonitors
  settings.pacing.pauseMonitors = paused -- reject.
end
settings.pacing = nil -- reject.
config.pacing = { pauseMonitors = 'yes' } -- reject.
config.bindings = { reload = { key = 'f5' } } -- reject.

return { config = config, settings = projected, metadata = metadata }
