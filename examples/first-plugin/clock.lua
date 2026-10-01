-- A contract: a capability and the service type behind it. A provider and
-- its consumers both require this module, and neither requires the other.

local plugin = require '@lunette-plugin'

local clock = {}

export type Service = {
  read now: (Service) -> number,
  read elapsed: (Service) -> number,
}

clock.capability = plugin.capability<<Service>> { name = 'example/clock', schema = 1 }

return clock
