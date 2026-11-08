-- Captures bounded opt-in host frame timings through a development wrist-menu toggle, without a panel or GPU timing.
local native = require '@lunette'
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local menu = require '@lunette-contracts/menu'
local logging = require '@lunette-plugins/diagnostics/desktop-logging'
local controller = require '@self/private/controller'
local exportName = require '@self/private/export-name'

local descriptor = schema.object {
  capacity = schema.default(schema.number { minimum = 1, maximum = 10000, integer = true })(5400),
  duration = schema.default(schema.number { minimum = 0.1, maximum = 120 })(30),
}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return plugin.consumer<<Config, Settings>> {
  name = 'dev/frame-trace',
  schema = descriptor,
  requires = { menu.capability },
  init = function(context: plugin.Context, settings: Settings): ()
    local menus = context:require(menu.capability)
    local action: menu.Registration? = nil
    local trace: controller.Controller
    trace = controller.new(context, {
      capacity = settings.capacity,
      duration = settings.duration,
      observe = native.observeFrameTiming,
      export = function(contents: string): ()
        local directory = lovr.filesystem.getSaveDirectory()
        local name = exportName.unique(os.date '!%Y%m%d-%H%M%S', lovr.filesystem.getDirectoryItems '')
        native.saveFile(directory, name, contents)
        logging.report('frame trace: exported ' .. directory .. '/' .. name, 'info')
      end,
      changed = function(): ()
        if action then
          action:update { selected = trace:status() == 'capturing' }
        end
      end,
    })
    action = menus:register(context, {
      id = 'dev/frame-trace/toggle',
      label = 'Frame trace',
      group = 'Development',
      selected = false,
      run = function(): ()
        trace:toggle()
      end,
    })
  end,
}
