-- Shows every standard kind on a panel in front of the user, with controls for the theme.
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local notifications = require '@lunette-contracts/notifications'
local ui = require '@lunette-plugins/ui/react'
local pages = require '@self/pages'

return plugin.consumer<<{}, {}>> {
  name = 'dev/ui-gallery',
  requires = { uiHost.capability, uiComponents.capability, notifications.capability },
  init = function(context: plugin.Context): ()
    local host = context:require(uiHost.capability)
    local components = context:require(uiComponents.capability)
    local panel = host:newPanel(context, {
      name = 'Widget gallery',
      width = 0.56,
      height = 0.5,
      pose = lovr.math.newMat4():translate(0.35, 1.35, -0.75):rotate(-0.35, 0, 1, 0),
    })
    ui.mount(
      panel,
      pages.Gallery {
        host = host,
        panel = panel,
        owner = context,
        components = components,
        notifications = context:require(notifications.capability),
      },
      { components = components, owner = context }
    )
  end,
}
