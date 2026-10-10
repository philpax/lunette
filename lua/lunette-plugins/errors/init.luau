-- Each activation owns its latest report, limiter, listeners, and native error subscription. A report received during delivery becomes the latest without recursive delivery. See docs/dev/lua-api.md#errors-stream.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/errors'
local limiter = require '@lunette-plugins/errors/limiter'
local listeners = require '@lunette-plugins/listeners'
local inspection = require '@lunette-contracts/inspection'
local config = require '@lunette-plugins/errors/config'

export type Service = contract.Service

export type Settings = config.Settings
export type Config = config.Config

local function build(context: plugin.Context, settings: Settings): Service
  local limit = limiter.new(settings.window, settings.maxKeys)
  local latest: contract.Report? = nil
  local reported = listeners.new<<(contract.Report) -> ()>>(context)
  local sequence = 0
  local delivering = false

  local function handle(message: string, traceback: string): ()
    -- Message and traceback together identify a repeated report.
    local deliver, suppressed = limit:record(message .. '\n' .. traceback, lovr.timer.getTime())
    if not deliver then
      return
    end
    local text = message .. '\n' .. traceback
    if suppressed > 0 then
      text ..= '\n(' .. suppressed .. ' identical error' .. (if suppressed == 1 then ' was' else 's were') .. ' suppressed since the last report)'
    end
    sequence += 1
    local report: contract.Report = table.freeze {
      message = message,
      traceback = traceback,
      suppressed = suppressed,
      text = text,
      sequence = sequence,
    }
    latest = report
    if delivering then
      return
    end
    delivering = true
    reported:each('errors: a listener', function(run: (contract.Report) -> ()): ()
      run(report)
    end)
    delivering = false
  end

  context:on {
    event = lunette.onError,
    run = function(event: lunette.ErrorEvent)
      handle(tostring(event.message), tostring(event.traceback or ''))
    end,
  }

  local service: Service = {
    inspect = function(_self: Service): inspection.Snapshot
      local result = reported:inspect 'errors.onReport'
      if context:active() then
        result[#result + 1] =
          inspection.registration('listener', 'errors.onError', context, nil, true, { nativeSubscription = true })
      end
      return inspection.snapshot(result, { sequence = sequence }, { 'limiter clock is not sampled' })
    end,
    onReport = function(_self: Service, owner: contract.Owner, listener: contract.Listener): plugin.Effect
      listeners.check('errors onReport', listener)
      return reported:add(owner, listener.run)
    end,
    latest = function(_self: Service): contract.Report?
      return latest
    end,
  }
  context:effect(function(): () -> ()
    return function(): ()
      latest = nil
      reported:clear()
    end
  end)
  return service
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'errors',
  capability = contract.capability,
  schema = config.schema,
  build = build,
}
