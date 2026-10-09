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

-- One window's pacer. `observe` records an observation and answers the rate in hertz, or nil for unthrottled.
export type Pacer = {
  read observe: (Pacer, Observation) -> number?,
}

export type Service = {
  read newPacer: (Service) -> Pacer,
}

export type Capability = plugin.Capability<Service>

pacing.capability = plugin.capability<<Service>> { name = 'lunette/pacing', version = 1 }

return pacing
