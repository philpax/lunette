-- Retains Reload during keyboard and panel outages, and scopes Keyboard and Hide panels to the services they drive.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local menu = require '@lunette-contracts/menu'
local display = require '@lunette-contracts/keyboard-display'
local panels = require '@lunette-contracts/panels'
local uiHost = require '@lunette-contracts/ui-host'
local logging = require '@lunette-plugins/diagnostics/desktop-logging'

export type Config = {}
export type Settings = {}

local keyboard = plugin.consumer<<Config, Settings>>({
  name = 'desktop/actions/keyboard',
  requires = { menu.capability, display.capability },
  init = function(context: plugin.Context, _settings: Settings): ()
    local menuService: menu.Service = context:require(menu.capability)
    local displayService: display.Service = context:require(display.capability)
    local toggle = menuService:register(context, {
      id = 'desktop/keyboard/toggle',
      label = 'Keyboard',
      group = 'Session',
      selected = displayService:isVisible(),
      run = function(): ()
        if context:active() then
          displayService:toggle()
        end
      end,
    })
    displayService:onChanged(context, {
      run = function(change: display.Change): ()
        if context:active() then
          toggle:update { selected = change.visible }
        end
      end,
    })
  end,
}).definition

-- Two overlapping panels while they show, and the same with a slash through them while they are hidden. They are
-- drawn white so that a renderer's tint gives them its ink.
local SHOWN_ICON =
  [[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="7" width="13" height="11" rx="2"/><path d="M8 4h11a2 2 0 0 1 2 2v9"/></svg>]]
local HIDDEN_ICON =
  [[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="7" width="13" height="11" rx="2" opacity="0.5"/><path d="M8 4h11a2 2 0 0 1 2 2v9" opacity="0.5"/><path d="M3 3l18 18"/></svg>]]

-- Hides every window and monitor panel, every toolkit panel but the essential ones such as the wrist menu, and the
-- keyboard, including panels that open while they are hidden, until it is chosen again. The overrides are this
-- activation's own, so a panel another plugin hides stays hidden when they are shown, and the keyboard returns where
-- it was, if it was up. The toolkit and the keyboard are optional, so their outages leave the window panels' toggle working.
local panelVisibility = plugin.consumer<<Config, Settings>>({
  name = 'desktop/actions/panels',
  requires = { menu.capability, panels.capability },
  init = function(context: plugin.Context, _settings: Settings): ()
    local menuService: menu.Service = context:require(menu.capability)
    local panelService: panels.Service = context:require(panels.capability)
    local toolkit = plugin.connectOptional(context, 'desktop/actions/panels/toolkit', uiHost.capability)
    local keyboard = plugin.connectOptional(context, 'desktop/actions/panels/keyboard', display.capability)
    local overrides: { plugin.Effect } = {}
    local hidden = false
    local function hide(panel: panels.Panel): ()
      if not panel.dead then
        table.insert(overrides, panel:setHidden(context, true))
      end
    end
    local toggle: menu.Registration
    toggle = menuService:register(context, {
      id = 'desktop/panels/hide',
      label = 'Hide panels',
      group = 'Session',
      icon = SHOWN_ICON,
      selected = false,
      run = function(): ()
        if not context:active() then
          return
        end
        hidden = not hidden
        if hidden then
          for _, panel in panelService:all() do
            hide(panel)
          end
          local host = toolkit()
          if host then
            table.insert(overrides, host.service:hidePanels(host.owner))
          end
          local board = keyboard()
          if board then
            table.insert(overrides, board.service:suppress(board.owner))
          end
        else
          for _, override in overrides do
            override:dispose()
          end
          table.clear(overrides)
        end
        toggle:update { selected = hidden, icon = if hidden then HIDDEN_ICON else SHOWN_ICON }
      end,
    })
    panelService:onAdded(context, {
      run = function(panel: panels.Panel): ()
        if hidden and context:active() then
          hide(panel)
        end
      end,
    })
  end,
}).definition

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/actions',
  requires = { menu.capability },
  init = function(context: plugin.Context, _settings: Settings): ()
    local menuService: menu.Service = context:require(menu.capability)
    menuService:register(context, {
      id = 'desktop/reload',
      label = 'Reload configuration',
      group = 'Session',
      run = function(): ()
        if not context:active() then
          return
        end
        local reloaded, message = lunette.reload()
        if not reloaded then
          logging.report('configuration was not reloaded: ' .. tostring(message), 'error')
        end
      end,
    })
    context:child(keyboard)
    context:child(panelVisibility)
  end,
}
