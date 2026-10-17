-- Shows every standard kind on a panel that the wrist menu opens, with controls for the theme.
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local notifications = require '@lunette-contracts/notifications'
local menu = require '@lunette-contracts/menu'
local ui = require '@lunette-plugins/ui/react'
local pluginManager = require '@lunette-contracts/plugin-manager'
local pages = require '@self/pages'
local settings = require '@self/settings'

return plugin.consumer<<{}, {}>> {
  name = 'dev/ui-gallery',
  requires = { uiHost.capability, uiComponents.capability, notifications.capability, menu.capability },
  init = function(context: plugin.Context): ()
    local host = context:require(uiHost.capability)
    local components = context:require(uiComponents.capability)
    local toasts = context:require(notifications.capability)
    local open: uiHost.Panel? = nil
    local registration: menu.Registration? = nil
    local function close(): ()
      if open then
        open:destroy()
        open = nil
      end
      if registration then
        registration:update { selected = false }
      end
    end
    registration = context:require(menu.capability):register(context, {
      id = 'dev/ui-gallery/open',
      label = 'Widget gallery',
      group = 'Development',
      run = function(): ()
        if open and not open.dead then
          close()
          return
        end
        -- The panel opens ahead of the user, or where it was last left, until it is grabbed and moved.
        local panel = host:newPanel(context, { name = 'Widget gallery', width = 0.56, height = 0.5 })
        ui.mount(
          panel,
          pages.Gallery {
            host = host,
            panel = panel,
            owner = context,
            components = components,
            notifications = toasts,
            onClose = close,
          },
          { components = components, owner = context }
        )
        open = panel
        if registration then
          registration:update { selected = true }
        end
      end,
    })
    -- The plugin manager shows the gallery's settings page when it selects the gallery.
    ui.contribute(context, pluginManager.settings, settings.page(host), { components = components })
  end,
}
