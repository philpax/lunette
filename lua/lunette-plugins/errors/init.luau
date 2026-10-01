-- The error stream provider.
--
-- Each activation owns a limiter, a bounded history, its subscribers, and
-- one lunette.onError subscription. The host logs every native error
-- whatever this provider does. Options: `window`, the seconds a repeated
-- report is withheld for; `maxKeys`, how many distinct reports the limiter
-- remembers; `history`, how many delivered reports recent answers; and
-- `clock`, which times reports. `@lunette-plugins/errors/format` and
-- `@lunette-plugins/errors/limiter` are the pure halves, for a presenter or
-- a replacement provider.
--
-- A report that arrives while subscribers are being called, such as a
-- subscriber's own error, joins the history and is not delivered, so a
-- presenter that raises on every report cannot feed itself.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/errors'
local format = require '@lunette-plugins/errors/format'
local limiter = require '@lunette-plugins/errors/limiter'
local protected = require '@lunette-plugins/protected'

export type Service = contract.Service

-- The resolved options. Each activation receives its own frozen copy.
export type Settings = {
  read window: number,
  read maxKeys: number,
  read history: number,
  read clock: () -> number,
}

-- What a configuration gives: every option optional.
export type Config = {
  read window: number?,
  read maxKeys: number?,
  read history: number?,
  read clock: (() -> number)?,
}

type Subscriber = {
  owner: contract.Owner,
  run: (contract.Report) -> (),
  cleared: (() -> ())?,
  active: boolean,
}

local SUBSCRIBER_KEYS: { [string]: boolean } = { run = true, cleared = true }

local function clock(): number
  if lovr and lovr.timer and lovr.timer.getTime then
    return lovr.timer.getTime()
  end
  return os.clock()
end

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
  local subscribers: { Subscriber } = {}
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
    for _, subscriber in ipairs(table.clone(subscribers)) do
      if subscriber.active and context:owns(subscriber.owner) then
        protected.call('errors: a subscriber', function(): ()
          subscriber.run(report)
        end)
      end
    end
    delivering = false
  end

  context:on {
    event = lunette.onError,
    run = function(event: lunette.ErrorEvent)
      handle(tostring(event.message), tostring(event.traceback or ''))
    end,
  }

  local service: Service = {
    subscribe = function(_self: Service, owner: contract.Owner, subscriber: contract.Subscriber): plugin.Effect
      if type(subscriber) ~= 'table' then
        error('errors subscribe: a subscriber is a table of fields, not a ' .. type(subscriber), 2)
      end
      for key, _ in subscriber :: { [unknown]: unknown } do
        if type(key) ~= 'string' or not SUBSCRIBER_KEYS[key] then
          error('errors subscribe: unknown field ' .. tostring(key) .. '; the fields are run and cleared', 2)
        end
      end
      if type(subscriber.run) ~= 'function' then
        error('errors subscribe: run is a function, not a ' .. type(subscriber.run), 2)
      end
      if subscriber.cleared ~= nil and type(subscriber.cleared) ~= 'function' then
        error('errors subscribe: cleared is a function, not a ' .. type(subscriber.cleared), 2)
      end
      local entry: Subscriber = { owner = owner, run = subscriber.run, cleared = subscriber.cleared, active = true }
      return context:acquire(owner, function(): () -> ()
        subscribers[#subscribers + 1] = entry
        return function(): ()
          entry.active = false
          local index = table.find(subscribers, entry)
          if index then
            table.remove(subscribers, index)
          end
        end
      end)
    end,
    recent = function(_self: Service): { contract.Report }
      return table.clone(history)
    end,
    clear = function(_self: Service, owner: contract.Owner): ()
      context:checkOwner(owner)
      table.clear(history)
      sequence = 0
      for _, subscriber in ipairs(table.clone(subscribers)) do
        local cleared = subscriber.cleared
        if cleared and subscriber.active and context:owns(subscriber.owner) then
          protected.call('errors: a subscriber', cleared)
        end
      end
    end,
  }
  context:effect(function(): () -> ()
    return function(): ()
      table.clear(history)
      table.clear(subscribers)
    end
  end)
  return service
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'errors',
  capability = contract.capability,
  defaults = {
    window = 5,
    maxKeys = 64,
    history = 32,
    clock = clock,
  },
  validate = validate,
  build = build,
}
