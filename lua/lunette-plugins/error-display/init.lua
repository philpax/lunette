-- The error-display provider.
--
-- Each activation owns a limiter, the current report, and one native error
-- subscription. Native callback logging remains independent of this provider.
-- The displayed surface is a direct quad, not a panels-provider visual.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/error-display'
local panels = require '@lunette-contracts/panels'
local format = require '@lunette-plugins/error-display/format'
local limiterModule = require '@lunette-plugins/error-display/limiter'
local panel = require '@lunette-plugins/error-display/panel'

export type Service = contracts.Service

type Context = plugin.Context
type Config = {
  read clock: (() -> number)?,
}

type State = {
  active: boolean,
  context: Context,
  clock: () -> number,
  limiter: limiterModule.Limiter,
  latest: string?,
  count: number,
}

local WINDOW = 5
local MAX_KEYS = 64
local X, Y, Z = 0, 1.4, -1.1
local WIDTH = 1.1
local TEXT_HEIGHT = 0.045
local COLUMNS = 64
local LINES = 6
local BACKGROUND: { number } = { 0.15, 0.03, 0.03, 0.85 }

local function clock(): number
  if lovr and lovr.timer and lovr.timer.getTime then
    return lovr.timer.getTime()
  end
  return os.clock()
end

local function stateFor(state: State): State
  if not state.active or not state.context:active() then
    error 'error-display: service is no longer active'
  end
  return state
end

local function reportText(message: string, traceback: string, suppressed: number): string
  return format.report(message, traceback, suppressed)
end

local function makeState(context: Context, config: Config): (State, Service)
  local current: State = {
    active = false,
    context = context,
    clock = clock,
    limiter = limiterModule.new(WINDOW, MAX_KEYS),
    latest = nil,
    count = 0,
  }
  local implementation: Service = {
    WINDOW = WINDOW,
    MAX_KEYS = MAX_KEYS,
    X = X,
    Y = Y,
    Z = Z,
    WIDTH = WIDTH,
    TEXT_HEIGHT = TEXT_HEIGHT,
    COLUMNS = COLUMNS,
    LINES = LINES,
    BACKGROUND = BACKGROUND,
    newLimiter = function(_self: Service, window: number?, maxKeys: number?): limiterModule.Limiter
      return limiterModule.new(window or WINDOW, maxKeys or MAX_KEYS)
    end,
    keyFor = function(_self: Service, message: string, traceback: string?): string
      return message .. '\n' .. tostring(traceback or '')
    end,
    handle = function(self: Service, message: string, traceback: string?, now: number?): boolean
      local owned = stateFor(current)
      local currentMessage = tostring(message)
      local currentTraceback = traceback and tostring(traceback) or debug.traceback('', 2)
      local shouldShow, suppressed =
        owned.limiter:record(self:keyFor(currentMessage, currentTraceback), now or owned.clock())
      if not shouldShow then
        return false
      end
      owned.latest = reportText(currentMessage, currentTraceback, suppressed)
      owned.count += 1
      return true
    end,
    show = function(_self: Service, message: string)
      local owned = stateFor(current)
      owned.latest = tostring(message)
      owned.count += 1
    end,
    clear = function(_self: Service)
      local owned = stateFor(current)
      owned.latest = nil
      owned.count = 0
    end,
    current = function(_self: Service): string?
      return stateFor(current).latest
    end,
    count = function(_self: Service): number
      return stateFor(current).count
    end,
    lines = function(_self: Service): { string }
      local owned = stateFor(current)
      return format.lines(owned, { columns = COLUMNS, lines = LINES })
    end,
    draw = function(_self: Service, pass: Pass): boolean
      local owned = stateFor(current)
      return panel.draw(owned, {
        x = X,
        y = Y,
        z = Z,
        width = WIDTH,
        textHeight = TEXT_HEIGHT,
        lines = LINES,
        columns = COLUMNS,
        background = BACKGROUND,
      }, pass, format.lines)
    end,
  }

  local service: Service = implementation
  current.active = true
  current.clock = config.clock or clock
  return current, service
end

local provided: plugin.Declaration = { errorDisplay = contracts.capability }
local required: plugin.Declaration = { panels = panels.capability }

local function initialize(context: Context, config: Config, provide: plugin.Publisher)
  local state, service = makeState(context, config)
  context:effect(function()
    local nativeCancel = lunette.onError(function(event: lunette.ErrorEvent)
      if not state.active or not context:active() then
        return
      end
      service:handle(event.message, event.traceback)
    end)
    return function()
      state.active = false
      nativeCancel()
      state.latest = nil
      state.count = 0
    end
  end)
  provide:provide(contracts.capability, service)
end

local function identity(config: Config): Config
  return config
end

local definition: plugin.Definition<Config> = plugin.define(identity, required, provided, initialize)

return { definition = definition }
