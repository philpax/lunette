-- The manager panel's content: the header with the close action, the browser, the sidebar, and the status line,
-- and the confirmation dialog's content.

local ui = require '@lunette-plugins/ui/react'
local controller = require '../composition/controller'
local model = require './model'
local browser = require './browser'
local sidebar = require './sidebar'

local app = {}

local Manager = ui.component('PluginManager', function(): ui.Child
  local c = ui.useComponents()
  local m = model.use()
  local state = m.state
  local entry = controller.selected(state)
  local status = controller.status(state)
  return c.Panel {
    title = 'Plugins',
    detail = if entry then entry.id else nil,
    onClose = m.close,
    c.HeaderActions {
      -- Default appearance is reachable here, beside the plugins that might have broken the interface.
      c.Button {
        key = 'appearance',
        label = if m.defaultAppearance() then 'Default look: on' else 'Default look',
        variant = 'band',
        onActivate = function(): ()
          m.change(function(): ()
            m.setDefaultAppearance(not m.defaultAppearance())
          end)
        end,
      },
    },
    c.Row {
      key = 'main',
      grow = 1,
      -- A zero height lets the row fill the panel without growing to its content's height.
      height = 0,
      gap = 'lg',
      padding = 'lg',
      align = 'stretch',
      browser.Browser { key = 'browser' },
      sidebar.Sidebar { key = 'sidebar' },
    },
    c.Row {
      key = 'footer',
      padding = 'sm',
      c.Text {
        key = 'status',
        text = if status == '' then ' ' else status,
        style = 'caption',
        color = 'muted',
        maxLines = 2,
        grow = 1,
      },
    },
  }
end)

-- The manager's content, with the model provided to its components.
function app.Root(value: model.Model): ui.Child
  return model.provide(value, Manager {})
end

export type ConfirmProps = {
  confirmation: controller.Confirmation,
  onConfirm: () -> (),
  onCancel: () -> (),
}

-- A confirmation dialog for an action that unloads plugins.
app.Confirm = ui.component('PluginConfirm', function(props: ConfirmProps): ui.Child
  local c = ui.useComponents()
  local confirmation = props.confirmation
  return c.Dialog {
    title = confirmation.title,
    actions = {
      { id = 'cancel', label = 'Cancel', variant = 'quiet', onActivate = props.onCancel },
      { id = 'confirm', label = confirmation.confirm, variant = 'danger', onActivate = props.onConfirm },
    },
    c.Text { key = 'body', text = confirmation.body, color = 'muted' },
  }
end)

return app
