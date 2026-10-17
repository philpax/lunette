-- Presents shared error reports on a UI host panel that appears when a report arrives, collapses repeated reports
-- into one entry with a count, and keeps a history that the overlay pages through after dismissal.
--
-- The panel uses the world presentation at a configured position. A follow panel would share the band below the
-- head that notification toasts occupy, and follow panels are reached by rays only; a world panel takes focus
-- normally, so focus traversal reaches dismissal, the history, and paging, and it stays put while a report is read.

local plugin = require '@lunette-plugin'
local errors = require '@lunette-contracts/errors'
local menu = require '@lunette-contracts/menu'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local ui = require '@lunette-plugins/ui/react'
local history = require '@self/private/history'
local view = require '@self/private/view'

local config = require '@self/config'

export type Config = config.Config
export type Settings = config.Settings

local PANEL = 'desktop/errors'
-- The tallest the content-sized panel grows, in metres.
local MAX_HEIGHT = 0.8

local required: plugin.Declaration = {
  errors.capability,
  uiHost.capability,
  uiComponents.capability,
}

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/errors',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local stream: errors.Service = context:require(errors.capability)
    local host: uiHost.Service = context:require(uiHost.capability)
    local components: uiComponents.Service = context:require(uiComponents.capability)
    local record = ui.store(history.new(settings.history))
    local state = ui.store({ mode = 'new', page = 1 } :: view.State)
    local panel = host:newPanel(context, {
      name = PANEL,
      pose = lovr.math.newMat4():translate(settings.position),
      width = settings.width,
      height = MAX_HEIGHT,
      size = 'content',
      grabbable = true,
      visible = false,
    })
    local shown = false
    -- The menu action, while a menu provider is loaded.
    local registration: menu.Registration? = nil

    local function live(): boolean
      return context:active() and not panel.dead
    end
    local function show(visible: boolean): ()
      if not live() or shown == visible then
        return
      end
      shown = visible
      panel:setVisible(visible)
      if registration then
        registration:update { selected = visible }
      end
    end
    local actions: view.Actions = table.freeze {
      dismiss = function(): ()
        if live() then
          record:set(history.dismiss(record:get()))
          state:set { mode = 'new', page = 1 }
          show(false)
        end
      end,
      setMode = function(mode: view.Mode): ()
        if live() then
          state:set { mode = mode, page = 1 }
        end
      end,
      setPage = function(page: number): ()
        if live() then
          state:set { mode = state:get().mode, page = page }
        end
      end,
    }
    ui.mount(
      panel,
      view.Overlay {
        history = record,
        state = state,
        actions = actions,
        width = settings.width,
        lines = settings.lines,
        pageSize = settings.page,
      },
      { components = components, owner = context }
    )

    -- A new report shows the overlay and brings the newest reports into view, unless the history is being read.
    local function receive(report: errors.Report): ()
      if not live() then
        return
      end
      record:set(history.record(record:get(), report))
      if state:get().mode == 'new' then
        state:set { mode = 'new', page = 1 }
      end
      show(true)
    end
    local latest = stream:latest()
    if latest then
      receive(latest)
    end
    stream:onReport(context, { run = receive })

    -- The history stays reachable after dismissal through the menu. A child keeps a missing menu provider from
    -- disabling the overlay.
    context:child(plugin.consumer<<{}, {}>>({
      name = 'desktop/errors/menu',
      requires = { menu.capability },
      init = function(child: plugin.Context, _settings: {}): ()
        local menus: menu.Service = child:require(menu.capability)
        local action = menus:register(child, {
          id = 'desktop/errors/history',
          label = 'Error history',
          group = 'Session',
          selected = shown,
          run = function(): ()
            if shown then
              actions.dismiss()
            else
              actions.setMode 'history'
              show(true)
            end
          end,
        })
        child:effect(function(): () -> ()
          registration = action
          return function(): ()
            registration = nil
          end
        end)
      end,
    }).definition)
  end,
}
