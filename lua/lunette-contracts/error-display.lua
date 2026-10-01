-- Error presentation without ownership of the native logging path.
--
-- The provider lifetime owns its error subscription. Native errors are always
-- logged independently; disabling this service removes only their presentation.
-- handle rate-limits reports, while show directly replaces the visible report.

local plugin = require '@lunette-plugin'

export type Limiter = {
  read window: number,
  read maxKeys: number,
  read record: (Limiter, string, number) -> (boolean, number),
  read suppressedCount: (Limiter, string) -> number,
}

-- What newLimiter takes: the window in seconds a repeated report is
-- suppressed for, and how many distinct reports it remembers.
export type LimiterOptions = {
  read window: number?,
  read maxKeys: number?,
}

-- A report: the error's message and where it was raised.
export type Report = {
  read message: string,
  read traceback: string?,
}

-- A report handled at a time, by default the provider's clock.
export type TimedReport = Report & {
  read now: number?,
}

export type Service = {
  read WINDOW: number,
  read MAX_KEYS: number,
  read X: number,
  read Y: number,
  read Z: number,
  read WIDTH: number,
  read TEXT_HEIGHT: number,
  read COLUMNS: number,
  read LINES: number,
  read BACKGROUND: { number },
  read newLimiter: (Service, LimiterOptions?) -> Limiter,
  read keyFor: (Service, Report) -> string,
  read handle: (Service, TimedReport) -> boolean,
  read show: (Service, string) -> (),
  read clear: (Service) -> (),
  read current: (Service) -> string?,
  read count: (Service) -> number,
  read lines: (Service) -> { string },
  read draw: (Service, Pass) -> boolean,
}

export type Capability = plugin.Capability<Service>

return {
  capability = plugin.capability<<Service>> { name = 'lunette/error-display', schema = 1 },
}
