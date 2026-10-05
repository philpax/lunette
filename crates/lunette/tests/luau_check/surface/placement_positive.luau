local lunette = require '@lunette'
local placement = require '@lunette-contracts/placement'
local panels = require '@lunette-contracts/panels'
local config = require '@lunette-plugins/placement/config'

local input: config.Config = {
  panelOptions = function(properties, window, base)
    local width: number? = properties.width
    local options: panels.Options = base(properties, window)
    return { width = width, title = options.title or window.title }
  end,
}
local settings: config.Settings = {
  panelOptions = function(properties, window, base)
    local width: number? = properties.width
    local options: panels.Options = base(properties, window)
    return { width = width, title = options.title or window.title }
  end,
}

local function call(settings: config.Settings, properties: placement.Properties, window: lunette.Window): panels.Options
  local callback = settings.panelOptions :: config.PanelOptions
  local function base(baseProperties: placement.Properties, _window: lunette.Window): panels.Options
    return { width = baseProperties.width }
  end
  return callback(properties, window, base)
end

return { input = input, settings = settings, call = call }
