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
  read newLimiter: (Service, number?, number?) -> Limiter,
  read keyFor: (Service, string, string?) -> string,
  read handle: (Service, string, string?, number?) -> boolean,
  read show: (Service, string) -> (),
  read clear: (Service) -> (),
  read current: (Service) -> string?,
  read count: (Service) -> number,
  read lines: (Service) -> { string },
  read draw: (Service, Pass) -> boolean,
}

export type Capability = plugin.Capability<Service>

return {
  capability = plugin.capability('lunette/error-display', 1, function(value: Service): Service
    return value
  end),
}
