-- Shows every standard kind on a panel that the wrist menu opens, with controls for the theme.
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local notifications = require '@lunette-contracts/notifications'
local menu = require '@lunette-contracts/menu'
local toggle = require '@lunette-plugins/menu/toggle'
local ui = require '@lunette-plugins/ui/react'
local pluginManager = require '@lunette-contracts/plugin-manager'
local pages = require '@self/pages'
local settings = require '@self/settings'
local schema = require '@lunette-plugin/schema'

-- Whether the gallery is open. Opening and closing it saves it, so the gallery opens at the next start as it was left.
local descriptor = schema.object { visible = schema.default(schema.boolean())(false) }
type Config = schema.Input<typeof(descriptor)>
type Settings = schema.Output<typeof(descriptor)>

return plugin.consumer<<Config, Settings>> {
  name = 'dev/ui-gallery',
  schema = descriptor,
  requires = { uiHost.capability, uiComponents.capability, notifications.capability, menu.capability },
  init = function(context: plugin.Context, options: Settings): ()
    local host = context:require(uiHost.capability)
    local components = context:require(uiComponents.capability)
    local toasts = context:require(notifications.capability)
    local open: uiHost.Panel? = nil
    local gallery: toggle.Toggle
    -- The panel opens ahead of the user, or where it was last left, until it is grabbed and moved.
    gallery = toggle.attach(context, context:require(menu.capability), {
      id = 'dev/ui-gallery/open',
      label = 'Widget gallery',
      group = 'Development',
      visible = options.visible,
      show = function(): ()
        local panel = host:newPanel(context, { name = 'Widget gallery', width = 0.56, height = 0.5 })
        ui.mount(
          panel,
          pages.Gallery {
            host = host,
            panel = panel,
            owner = context,
            components = components,
            notifications = toasts,
            onClose = function(): ()
              gallery:set(false)
            end,
          },
          { components = components, owner = context }
        )
        open = panel
      end,
      hide = function(): ()
        if open then
          open:destroy()
          open = nil
        end
      end,
    })
    -- The plugin manager shows the gallery's settings page when it selects the gallery.
    ui.contribute(context, pluginManager.settings, settings.page(host), { components = components })
  end,
}
