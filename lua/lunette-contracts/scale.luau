-- Each chooser tracks one output's scale in discrete steps with hysteresis. It holds no native resource.

local plugin = require '@lunette-plugin'

local scale = {}

-- `reset` clears hysteresis history before the next choice.
export type Chooser = {
  read choose: (Chooser, number) -> (number, boolean),
  read current: (Chooser) -> number?,
  read reset: (Chooser) -> (),
}

export type Service = {
  read newChooser: (Service) -> Chooser,
}

export type Capability = plugin.Capability<Service>

scale.capability = plugin.capability<<Service>> { name = 'lunette/scale', schema = 1 }

return scale
