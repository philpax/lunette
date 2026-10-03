-- The frame pacing contract. The service hands out pacers, each choosing one window's frame rate from what
-- each frame observed. A pacer holds no native resource, so it is not owner-scoped. See
-- docs/dev/lua-api.md#frame-pacing-and-output-scale and docs/dev/rendering.md.

local plugin = require '@lunette-plugin'
local vocabulary = require '@lunette-contracts/vocabulary'

local pacing = {}

export type ContentType = vocabulary.ContentType

-- What one frame observed about a window. `drew` is whether the client committed a buffer since the previous
-- observation, or nil when the caller cannot tell, such as while the throttle shapes the commits.
export type Observation = {
  read visible: boolean,
  read contentType: ContentType?,
  read drew: boolean?,
}

-- One window's pacer. `observe` records an observation and answers the rate
-- in hertz, or nil for unthrottled, and whether the rate differs from the
-- previous answer. `current` answers the latest rate. `isExempt` answers
-- whether a window with that hint, and this pacer's history, is exempt from
-- throttling. `reset` forgets the history and the latest rate.
export type Pacer = {
  read observe: (Pacer, Observation) -> (number?, boolean),
  read current: (Pacer) -> number?,
  read isExempt: (Pacer, ContentType?) -> boolean,
  read reset: (Pacer) -> (),
}

export type Service = {
  read newPacer: (Service) -> Pacer,
}

export type Capability = plugin.Capability<Service>

pacing.capability = plugin.capability<<Service>> { name = 'lunette/pacing', schema = 1 }

return pacing
