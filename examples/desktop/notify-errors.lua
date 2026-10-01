-- An error presenter that sends each report as a desktop notification.
--
-- It subscribes to the lunette/errors stream, which has already rate-limited
-- the reports, and runs notify-send with the first line of each. It presents
-- beside the shipped error panel rather than instead of it; disabling the
-- `desktop/errors` entry leaves this the only presenter. `program` names the
-- notifier, and a notifier that does not start is reported once.
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
