-- Notifications use the rate-limited error stream and include each report's first line. Spawn failure is reported once.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local errors = require '@lunette-contracts/errors'

export type Config = {
  read program: string?,
}

type Settings = {
  read program: string,
}

local DEFAULTS: Settings = { program = 'notify-send' }

return plugin.define {
  name = 'notify-errors',
  requires = { errors = errors.capability },
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher)
    local settings: Settings = plugin.options { name = 'notify-errors', defaults = DEFAULTS, config = config }
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
}
