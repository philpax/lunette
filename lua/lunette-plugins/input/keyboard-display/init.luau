-- Provides session keyboard visibility and placement.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local display = require '@lunette-contracts/keyboard-display'
local surfaces = require '@lunette-contracts/surfaces'
local ui = require '@lunette-contracts/ui'
local config = require '@self/config'
local create = require '@self/private/display'

export type Config = config.Config
export type Settings = config.Settings
export type Service = display.Service

return plugin.provider<<Config, Settings, Service>> {
  name = 'desktop/keyboard',
  capability = display.capability,
  requires = {
    frame.capability,
    focus.capability,
    keyboard.capability,
    surfaces.capability,
    ui.capability,
  },
  schema = config.schema,
  build = create,
}
