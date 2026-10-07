-- Provides session keyboard visibility while retaining the compatibility wrist button.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local display = require '@lunette-contracts/keyboard-display'
local surfaces = require '@lunette-contracts/surfaces'
local config = require '@lunette-plugins/desktop/keyboard/config'
local create = require '@lunette-plugins/desktop/keyboard/display'
local wrist = require '@lunette-plugins/desktop/keyboard/wrist'

export type Hand = config.Hand
export type Config = config.Config
export type Settings = config.Settings
export type Service = display.Service

return plugin.provider<<Config, Settings, Service>>({
  name = 'desktop/keyboard',
  capability = display.capability,
  requires = {
    frame = frame.capability,
    focus = focus.capability,
    keyboard = keyboard.capability,
    surfaces = surfaces.capability,
  },
  schema = config.schema,
  build = function(context: plugin.Context, settings: Settings): Service
    local service = create(context, settings)
    wrist(context, settings, service)
    return service
  end,
}).definition
