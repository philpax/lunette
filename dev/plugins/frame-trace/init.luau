-- Captures bounded opt-in host frame timings through development wrist-menu actions, without a panel or GPU timing.
local native = require '@lunette'
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local menu = require '@lunette-contracts/menu'
local logging = require '@lunette-plugins/diagnostics/desktop-logging'
local controller = require '@self/private/controller'

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
    local actions: { [string]: menu.Registration } = {}
    local trace: controller.Controller
    local function changed(): ()
      local status = trace:status()
      local running = status == 'capturing'
      local completed = status == 'complete' or status == 'stopped'
      if actions.start then
        actions.start:update { enabled = not running }
        actions.stop:update { enabled = running }
        actions.export:update { enabled = completed }
        actions.cancel:update { enabled = running or completed }
      end
      if status == 'complete' then
        logging.report('frame trace: capture complete; Export frame trace is available in the Development menu', 'info')
      end
    end
    trace = controller.new(context, {
      capacity = settings.capacity,
      duration = settings.duration,
      observe = native.observeFrameTiming,
      export = function(contents: string): ()
        local directory = lovr.filesystem.getSaveDirectory()
        native.saveFile(directory, 'frame-trace.csv', contents)
        logging.report('frame trace: exported ' .. directory .. '/frame-trace.csv', 'info')
      end,
      changed = changed,
    })
    for _, action in
      {
        {
          key = 'start',
          label = 'Start frame trace',
          run = function(): ()
            trace:start()
          end,
        },
        {
          key = 'stop',
          label = 'Stop frame trace',
          run = function(): ()
            trace:stop()
          end,
        },
        {
          key = 'export',
          label = 'Export frame trace',
          run = function(): ()
            trace:export()
          end,
        },
        {
          key = 'cancel',
          label = 'Cancel frame trace',
          run = function(): ()
            trace:cancel()
          end,
        },
      }
    do
      actions[action.key] = menus:register(context, {
        id = 'dev/frame-trace/' .. action.key,
        label = action.label,
        group = 'Development',
        enabled = action.key == 'start',
        run = action.run,
      })
    end
  end,
}
