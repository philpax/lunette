local config = require '@lunette-plugins/placement/config'

local wrongReceiver: config.Settings = {
  panelOptions = function(_properties, _window: string, _base) -- reject.
    return {}
  end,
}
local wrongProperty: config.Settings = {
  panelOptions = function(_properties: { read width: string }, _window, _base) -- reject.
    return {}
  end,
}

local wrongInputReceiver: config.Config = {
  panelOptions = function(_properties, _window: string, _base) -- reject.
    return {}
  end,
}
local wrongInputProperty: config.Config = {
  panelOptions = function(_properties: { read width: string }, _window, _base) -- reject.
    return {}
  end,
}

return { wrongReceiver, wrongProperty, wrongInputReceiver, wrongInputProperty }
