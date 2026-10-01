-- The error-display provider.
--
-- Each activation owns a limiter, the current report, and one native error
-- subscription. Native callback logging remains independent of this provider.
-- The displayed surface is a direct quad, not a panels-provider visual.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/error-display'
local format = require '@lunette-plugins/error-display/format'
local limiterModule = require '@lunette-plugins/error-display/limiter'
local panel = require '@lunette-plugins/error-display/panel'

export type Service = contracts.Service

type Context = plugin.Context

-- The resolved options: the limiter's window and capacity, where the display
-- is drawn and how large, its background, and the clock reports are timed by.
-- Each activation receives its own frozen copy, so no consumer can recolour
-- another's display.
export type Settings = {
  read window: number,
  read maxKeys: number,
  read x: number,
  read y: number,
  read z: number,
  read width: number,
  read textHeight: number,
  read columns: number,
  read lines: number,
  read background: { number },
  read clock: () -> number,
}

-- What a configuration gives: every option optional.
export type Config = {
  read window: number?,
  read maxKeys: number?,
  read x: number?,
  read y: number?,
  read z: number?,
  read width: number?,
  read textHeight: number?,
  read columns: number?,
  read lines: number?,
  read background: { number }?,
  read clock: (() -> number)?,
}

type State = {
  context: Context,
  clock: () -> number,
  limiter: limiterModule.Limiter,
  latest: string?,
  count: number,
}

local function clock(): number
  if lovr and lovr.timer and lovr.timer.getTime then
    return lovr.timer.getTime()
  end
  return os.clock()
end

local function reportText(message: string, traceback: string, suppressed: number): string
  return format.report(message, traceback, suppressed)
end

local function makeState(context: Context, settings: Settings): (State, Service)
  local WINDOW, MAX_KEYS = settings.window, settings.maxKeys
  local X, Y, Z = settings.x, settings.y, settings.z
  local WIDTH, TEXT_HEIGHT = settings.width, settings.textHeight
  local COLUMNS, LINES = settings.columns, settings.lines
  local BACKGROUND = settings.background
  local current: State = {
    context = context,
    clock = settings.clock,
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
    newLimiter = function(_self: Service, options: contracts.LimiterOptions?): limiterModule.Limiter
      local window = options and options.window
      local maxKeys = options and options.maxKeys
      return limiterModule.new(window or WINDOW, maxKeys or MAX_KEYS)
    end,
    keyFor = function(_self: Service, report: contracts.Report): string
      return report.message .. '\n' .. tostring(report.traceback or '')
    end,
    handle = function(self: Service, report: contracts.TimedReport): boolean
      local message, traceback, now = report.message, report.traceback, report.now
      local currentMessage = tostring(message)
      local currentTraceback = traceback and tostring(traceback) or debug.traceback('', 2)
      local shouldShow, suppressed = current.limiter:record(
        self:keyFor { message = currentMessage, traceback = currentTraceback },
        now or current.clock()
      )
      if not shouldShow then
        return false
      end
      current.latest = reportText(currentMessage, currentTraceback, suppressed)
      current.count += 1
      return true
    end,
    show = function(_self: Service, message: string)
      current.latest = tostring(message)
      current.count += 1
    end,
    clear = function(_self: Service)
      current.latest = nil
      current.count = 0
    end,
    current = function(_self: Service): string?
      return current.latest
    end,
    count = function(_self: Service): number
      return current.count
    end,
    lines = function(_self: Service): { string }
      return format.lines(current, { columns = COLUMNS, lines = LINES })
    end,
    draw = function(_self: Service, pass: Pass): boolean
      return panel.draw(current, {
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
  return current, service
end

-- The published service is revoked with this activation, so its methods need
-- no liveness guard. The subscription is an effect of the activation, and it
-- delivers nothing once the activation has ended.
local function build(context: Context, settings: Settings): Service
  local state, service = makeState(context, settings)
  context:effect(function()
    return function()
      state.latest = nil
      state.count = 0
    end
  end)
  context:on {
    event = lunette.onError,
    run = function(event: lunette.ErrorEvent)
      service:handle { message = event.message, traceback = event.traceback }
    end,
  }
  return service
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'error-display',
  capability = contracts.capability,
  defaults = {
    window = 5,
    maxKeys = 64,
    x = 0,
    y = 1.4,
    z = -1.1,
    width = 1.1,
    textHeight = 0.045,
    columns = 64,
    lines = 6,
    background = { 0.15, 0.03, 0.03, 0.85 },
    clock = clock,
  },
  build = build,
}
