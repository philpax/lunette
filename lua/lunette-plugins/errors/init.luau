-- Each activation owns its history, limiter, subscribers, and native error subscription. Reports received during delivery enter history without recursive delivery. See docs/dev/lua-api.md#errors-stream.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/errors'
local format = require '@lunette-plugins/errors/format'
local limiter = require '@lunette-plugins/errors/limiter'
local listeners = require '@lunette-plugins/listeners'
local inspection = require '@lunette-contracts/inspection'

export type Service = contract.Service

local config = require '@lunette-plugins/errors/config'

export type Settings = config.Settings
export type Config = config.Config

local SUBSCRIBER_KEYS: { [string]: boolean } = { run = true, cleared = true }

local function validate(settings: Settings, name: string): ()
  if not (settings.window >= 0) then
    error('plugin ' .. name .. ': option window is zero or more seconds, not ' .. settings.window, 0)
  end
  for _, option in ipairs { 'maxKeys', 'history' } do
    local value = (settings :: any)[option]
    if value < 1 or value ~= math.floor(value) then
      error('plugin ' .. name .. ': option ' .. option .. ' is a whole number of at least 1, not ' .. value, 0)
    end
  end
end

local function build(context: plugin.Context, settings: Settings): Service
  local limit = limiter.new(settings.window, settings.maxKeys)
  local history: { contract.Report } = {}
  local subscribers = listeners.new<<contract.Subscriber>>(context)
  local sequence = 0
  local delivering = false

  local function remember(report: contract.Report): ()
    history[#history + 1] = report
    while #history > settings.history do
      table.remove(history, 1)
    end
  end

  local function handle(message: string, traceback: string): ()
    local now = settings.clock()
    local deliver, suppressed = limit:record(format.key { message = message, traceback = traceback }, now)
    if not deliver then
      return
    end
    sequence += 1
    local report: contract.Report = table.freeze {
      message = message,
      traceback = traceback,
      suppressed = suppressed,
      text = format.report(message, traceback, suppressed),
      sequence = sequence,
      time = now,
    }
    remember(report)
    if delivering then
      return
    end
    delivering = true
    subscribers:each('errors: a subscriber', function(subscriber): ()
      subscriber.run(report)
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
      local result = subscribers:inspect 'errors.subscribe'
      if context:active() then
        result[#result + 1] =
          inspection.registration('listener', 'errors.onError', context, nil, true, { nativeSubscription = true })
      end
      return inspection.snapshot(result, {
        history = #history,
        sequence = sequence,
        delivering = delivering,
        historyLimit = settings.history,
        window = settings.window,
        maxKeys = settings.maxKeys,
      }, { 'limiter clock is not sampled' })
    end,
    subscribe = function(_self: Service, owner: contract.Owner, subscriber: contract.Subscriber): plugin.Effect
      if type(subscriber) ~= 'table' then
        error('errors subscribe: a subscriber is a table of fields, not a ' .. type(subscriber), 2)
      end
      plugin.rejectUnknownFields('errors subscribe', subscriber, SUBSCRIBER_KEYS, 'run and cleared', 2)
      if type(subscriber.run) ~= 'function' then
        error('errors subscribe: run is a function, not a ' .. type(subscriber.run), 2)
      end
      if subscriber.cleared ~= nil and type(subscriber.cleared) ~= 'function' then
        error('errors subscribe: cleared is a function, not a ' .. type(subscriber.cleared), 2)
      end
      return subscribers:add(
        owner,
        { run = subscriber.run, cleared = subscriber.cleared },
        { cleared = subscriber.cleared ~= nil }
      )
    end,
    recent = function(_self: Service): { contract.Report }
      return table.clone(history)
    end,
    clear = function(_self: Service, owner: contract.Owner): ()
      context:checkOwner(owner)
      table.clear(history)
      sequence = 0
      subscribers:each('errors: a subscriber', function(subscriber): ()
        local cleared = subscriber.cleared
        if cleared then
          cleared()
        end
      end)
    end,
  }
  context:effect(function(): () -> ()
    return function(): ()
      table.clear(history)
      subscribers:clear()
    end
  end)
  return service
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'errors',
  capability = contract.capability,
  schema = config,
  validate = validate,
  build = build,
}
