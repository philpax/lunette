-- Retains Reload during keyboard outages and scopes Keyboard to its display activation.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local menu = require '@lunette-contracts/menu'
local display = require '@lunette-contracts/keyboard-display'
local logging = require '@lunette-plugins/desktop/logging'

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
      order = 10,
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

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/actions',
  requires = { menu.capability },
  init = function(context: plugin.Context, _settings: Settings): ()
    local menuService: menu.Service = context:require(menu.capability)
    menuService:register(context, {
      id = 'desktop/reload',
      label = 'Reload configuration',
      group = 'Session',
      order = 30,
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
  end,
}).definition
