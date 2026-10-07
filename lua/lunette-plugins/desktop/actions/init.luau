-- Retains Reload during keyboard outages and scopes Keyboard to its display activation.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local menu = require '@lunette-contracts/menu'
local display = require '@lunette-contracts/keyboard-display'
local logging = require '@lunette-plugins/desktop/logging'

local descriptor = schema.object {}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

local keyboard = plugin.consumer<<Config, Settings>>({
  name = 'desktop/actions/keyboard',
  schema = descriptor,
  requires = { menu = menu.capability, display = display.capability },
  init = function(context: plugin.Context, _settings: Settings): ()
    local menuService: menu.Service = context:require(menu.capability)
    local displayService: display.Service = context:require(display.capability)
    local toggle = menuService:register(context, {
      id = 'desktop/keyboard/toggle',
      label = 'Keyboard',
      group = 'Session',
      order = 10,
      enabled = not displayService.dead,
      selected = not displayService.dead and displayService:isVisible(),
      run = function(): ()
        if context:active() and not displayService.dead then
          displayService:toggle()
        end
      end,
    })
    displayService:onChanged(context, {
      run = function(change: display.Change): ()
        if context:active() then
          menuService:update(context, toggle, { enabled = not displayService.dead, selected = change.visible })
        end
      end,
    })
  end,
}).definition

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/actions',
  schema = descriptor,
  requires = { menu = menu.capability },
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
    context:child(keyboard, {})
  end,
}).definition
