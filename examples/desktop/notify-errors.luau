-- Notifications use the rate-limited error stream and include each report's first line. Spawn failure is reported once.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local errors = require '@lunette-contracts/errors'

local schema = require '@lunette-plugin/schema'

local descriptor = schema.object { program = schema.default(schema.string()) 'notify-send' }
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return plugin.consumer<<Config, Settings>>({
  name = 'notify-errors',
  requires = { errors = errors.capability },
  schema = descriptor,
  init = function(context: plugin.Context, settings: Settings)
    local stream: errors.Service = context:require(errors.capability)
    local failed = false
    context:on {
      event = lunette.onProcessExited,
      run = function(event: lunette.ProcessExitedEvent)
        if event.outcome == 'spawnFailed' and not failed then
          failed = true
          local log = lovr.log
          if log then
            log(settings.program .. ' did not start, so errors are not notified', 'warn', 'notify-errors')
          end
        end
      end,
    }
    stream:subscribe(context, {
      run = function(report: errors.Report)
        if failed then
          return
        end
        local summary = report.message:match '^[^\n]*' or report.message
        lunette.spawn { argv = { settings.program, '--app-name=lunette', 'lunette error', summary } }
      end,
    })
  end,
}).definition
