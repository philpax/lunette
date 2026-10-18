-- Adds the Plugins wrist-menu action and the panel that inspects and manages the session's composition.
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local frame = require '@lunette-contracts/frame'
local composition = require '@lunette-contracts/composition'
local menu = require '@lunette-contracts/menu'
local focusContract = require '@lunette-contracts/focus'
local config = require '@self/config'
local shell = require '@self/private/presentation/shell'

export type Config = config.Config
export type Settings = config.Settings

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/manager',
  schema = config.schema,
  requires = {
    composition.capability,
    frame.capability,
    uiHost.capability,
    uiComponents.capability,
    menu.capability,
    focusContract.capability,
  },
  init = function(context: plugin.Context, settings: Settings): ()
    local host = context:require(uiHost.capability)
    shell.start(context, settings, {
      composition = context:require(composition.capability),
      frame = context:require(frame.capability),
      menu = context:require(menu.capability),
      host = host,
      components = context:require(uiComponents.capability),
      focus = context:require(focusContract.capability),
      open = function(options: uiHost.PanelOptions): uiHost.Panel
        return host:newPanel(context, options)
      end,
    })
  end,
}
