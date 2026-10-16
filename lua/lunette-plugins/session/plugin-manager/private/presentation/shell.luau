-- Owns the manager panel, its confirmation dialog, the wrist-menu action, and the refresh while the panel is shown.
-- The controller owns composition and draft decisions.

local plugin = require '@lunette-plugin'
local ui = require '@lunette-plugins/ui/react'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local composition = require '@lunette-contracts/composition'
local frame = require '@lunette-contracts/frame'
local menu = require '@lunette-contracts/menu'
local focus = require '@lunette-contracts/focus'
local notifications = require '@lunette-contracts/notifications'
local config = require '../../config'
local controller = require '../composition/controller'
local brokers = require '../inspection/brokers'
local graphKinds = require './graph-kinds'
local model = require './model'
local graphView = require './graph-view'
local app = require './app'

local shell = {}

export type Services = {
  read composition: composition.Service,
  read frame: frame.Service,
  read menu: menu.Service,
  read host: uiHost.Service,
  read components: uiComponents.Service,
  read focus: focus.Service,
  -- Creates a panel owned by the manager.
  read open: (uiHost.PanelOptions) -> uiHost.Panel,
}

-- Width of the sidebar as a share of the panel, up to a maximum in metres.
local SIDEBAR_SHARE, SIDEBAR_MAXIMUM = 0.4, 0.42

-- Reports a failed action as a notification while a notifications provider is loaded. A child consumer keeps a
-- missing provider from disabling the manager.
local function notifier(context: plugin.Context): (string, string) -> ()
  local current: notifications.Service? = nil
  local owner: plugin.Owner? = nil
  local child = plugin.consumer<<{}, {}>> {
    name = 'desktop/manager/notify',
    requires = { notifications.capability },
    init = function(childContext: plugin.Context, _settings: {}): ()
      local service = childContext:require(notifications.capability)
      childContext:effect(function(): () -> ()
        current, owner = service, childContext
        return function(): ()
          current, owner = nil, nil
        end
      end)
    end,
  }
  context:child(child.definition)
  return function(title: string, body: string): ()
    local service, poster = current, owner
    if service and poster then
      service:notify(poster, { title = title, body = body, level = 'error' })
    end
  end
end

function shell.start(context: plugin.Context, settings: config.Settings, services: Services): ()
  local state = controller.new(services.composition, brokers.watch(context))
  state.presentation = settings.view
  local notify = notifier(context)
  local kinds = graphKinds.register(services.host, context)
  local revision = ui.store(0)
  local dead = false
  local visible = settings.visible
  local untilRefresh = settings.refreshInterval
  local registration: menu.Registration? = nil
  local panel = services.open {
    name = 'desktop/manager',
    pose = lovr.math.newMat4():translate(settings.position),
    width = settings.width,
    height = settings.height,
    grabbable = true,
  }
  local dialog: uiHost.Panel? = nil
  local canvas: uiHost.Ref = { current = nil }
  -- The session focus target a text field of the panel took, returned when the field's edit ends.
  local keyboard: focus.TargetHandle? = nil

  local function render(): ()
    revision:set(revision:get() + 1)
  end
  local function closeDialog(): ()
    local open = dialog
    dialog = nil
    if open and not open.dead then
      open:destroy()
    end
  end
  local function run(id: string): ()
    local button = controller.button(state, id)
    local ok = controller.invoke(state, id)
    if not ok and button and button.enabled then
      notify(`{button.label} failed`, state.message)
    end
    render()
  end
  local function confirm(confirmation: controller.Confirmation): ()
    closeDialog()
    local opened = services.open {
      name = 'desktop/manager/confirm',
      presentation = 'dialog',
      parent = panel,
      modality = 'panel',
    }
    dialog = opened
    ui.mount(
      opened,
      app.Confirm {
        confirmation = confirmation,
        onConfirm = function(): ()
          closeDialog()
          controller.update(state)
          local selected = controller.selected(state)
          if selected and selected.id == confirmation.entry then
            run(confirmation.action)
          else
            state.message = 'The selection changed, so the action did not run.'
            render()
          end
        end,
        onCancel = closeDialog,
      },
      { components = services.components, owner = context }
    )
  end
  local function releaseField(): ()
    local target = keyboard
    keyboard = nil
    if target and not target.dead and services.focus:focused() == target then
      target:blur()
    end
  end
  local function setVisible(show: boolean): ()
    if dead or panel.dead then
      return
    end
    visible = show
    panel:setVisible(show)
    if show then
      untilRefresh = settings.refreshInterval
    else
      closeDialog()
      releaseField()
      controller.graphCancel(state)
      controller.endSearch(state)
      controller.cancelText(state)
    end
    controller.update(state)
    render()
    local handle = registration
    if handle then
      handle:update { selected = show }
    end
  end

  local value: model.Model = {
    state = state,
    revision = revision,
    change = function(change: () -> ()): ()
      change()
      render()
    end,
    invoke = function(id: string): ()
      local confirmation = controller.confirmation(state, id)
      if confirmation then
        confirm(confirmation)
      else
        run(id)
      end
    end,
    close = function(): ()
      setVisible(false)
    end,
    kinds = kinds,
    sidebarWidth = math.min(SIDEBAR_MAXIMUM, settings.width * SIDEBAR_SHARE),
    canvas = canvas,
    focusField = function(node: uiHost.Node): ()
      if node:focus() then
        keyboard = services.focus:focused()
      end
    end,
    releaseField = releaseField,
  }
  panel:setVisible(visible)
  ui.mount(panel, app.Root(value), { components = services.components, owner = context })
  context:effect(function(): () -> ()
    return function(): ()
      dead = true
      closeDialog()
    end
  end)
  registration = services.menu:register(context, {
    id = 'desktop/manager/open',
    label = 'Plugins',
    group = 'Session',
    order = 20,
    selected = visible,
    run = function(): ()
      setVisible(not visible)
    end,
  })
  services.frame:onUpdate(context, {
    phase = 'scene',
    run = function(dt: number): ()
      if dead or panel.dead or not visible then
        return
      end
      -- The canvas has its size after layout, and the camera fits the graph once it has one.
      local node = canvas.current
      if node and not node.dead and state.presentation == 'graph' then
        local scale = graphView.PIXEL
        if controller.resize(state, node.bounds.width / scale, node.bounds.height / scale) then
          render()
        end
      end
      untilRefresh -= dt
      if untilRefresh <= 0 then
        untilRefresh = settings.refreshInterval
        controller.update(state)
        render()
      end
    end,
  })
end

return shell
