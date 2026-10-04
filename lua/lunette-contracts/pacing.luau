-- Each pacer tracks frame observations for one window and holds no native resources.

local plugin = require '@lunette-plugin'
local vocabulary = require '@lunette-contracts/vocabulary'

local pacing = {}

export type ContentType = vocabulary.ContentType

-- `drew` is nil when the caller cannot determine whether the client committed a buffer since the prior observation.
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
