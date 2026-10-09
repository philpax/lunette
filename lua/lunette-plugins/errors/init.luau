-- Each activation owns its history, limiter, listeners, and native error subscription. Reports received during delivery enter history without recursive delivery. See docs/dev/lua-api.md#errors-stream.

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

local LISTENER_KEYS: { string } = { 'run' }

local function build(context: plugin.Context, settings: Settings): Service
  local limit = limiter.new(settings.window, settings.maxKeys)
  local history: { contract.Report } = {}
  local reported = listeners.new<<(contract.Report) -> ()>>(context)
  local sequence = 0
  local delivering = false

  local function remember(report: contract.Report): ()
    history[#history + 1] = report
    while #history > settings.history do
      table.remove(history, 1)
    end
  end

  local function handle(message: string, traceback: string): ()
    -- Message and traceback together identify a repeated report.
    local deliver, suppressed = limit:record(message .. '\n' .. traceback, settings.clock())
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
    remember(report)
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
      return inspection.snapshot(
        result,
        { history = #history, sequence = sequence },
        { 'limiter clock is not sampled' }
      )
    end,
    onReport = function(_self: Service, owner: contract.Owner, listener: contract.Listener): plugin.Effect
      if type(listener) ~= 'table' then
        error('errors onReport: a listener is a table of fields, not a ' .. type(listener), 2)
      end
      plugin.rejectUnknownFields('errors onReport', listener, LISTENER_KEYS, 2)
      if type(listener.run) ~= 'function' then
        error('errors onReport: run is a function, not a ' .. type(listener.run), 2)
      end
      return reported:add(owner, listener.run)
    end,
    recent = function(_self: Service): { contract.Report }
      return table.clone(history)
    end,
  }
  context:effect(function(): () -> ()
    return function(): ()
      table.clear(history)
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
