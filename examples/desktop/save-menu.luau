-- Menu actions save and restore the arrangement through the configured arrangement provider.
local plugin = require '@lunette-plugin'
local arrangement = require '@lunette-contracts/arrangement'
local menu = require '@lunette-contracts/menu'

export type Config = {}
export type Settings = {}

return plugin.consumer<<Config, Settings>> {
  name = 'save-menu',
  requires = { arrangement.capability, menu.capability },
  init = function(context: plugin.Context, _settings: Settings)
    local saved: arrangement.Service = context:require(arrangement.capability)
    local actions: menu.Service = context:require(menu.capability)
    actions:register(context, {
      id = 'example/save-arrangement',
      label = 'Save arrangement',
      group = 'Examples',
      run = function()
        if not context:active() then
          return
        end
        local written, message = saved:save()
        local log = lovr.log
        if not written and log then
          log('the arrangement was not saved: ' .. tostring(message), 'warn', 'save-menu')
        end
      end,
    })
    actions:register(context, {
      id = 'example/restore-arrangement',
      label = 'Restore arrangement',
      group = 'Examples',
      run = function()
        if context:active() then
          saved:restore()
        end
      end,
    })
  end,
}
