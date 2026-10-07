-- Menu actions save and restore the arrangement through the configured arrangement provider.
local plugin = require '@lunette-plugin'
local arrangement = require '@lunette-contracts/arrangement'
local menu = require '@lunette-contracts/menu'

local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return plugin.consumer<<Config, Settings>>({
  name = 'save-menu',
  requires = { arrangement = arrangement.capability, menu = menu.capability },
  schema = descriptor,
  init = function(context: plugin.Context, _settings: Settings)
    local saved: arrangement.Service = context:require(arrangement.capability)
    local actions: menu.Service = context:require(menu.capability)
    actions:register(context, {
      id = 'example/save-arrangement',
      label = 'Save arrangement',
      group = 'Examples',
      order = 2,
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
      order = 3,
      run = function()
        if context:active() then
          saved:restore()
        end
      end,
    })
  end,
}).definition
