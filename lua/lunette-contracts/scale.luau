-- Each chooser tracks one output's scale in discrete steps with hysteresis. It holds no native resource.

local plugin = require '@lunette-plugin'

local scale = {}

-- `choose` takes a distance in metres and answers the output scale.
export type Chooser = {
  read choose: (Chooser, number) -> number,
}

export type Service = {
  read newChooser: (Service) -> Chooser,
}

export type Capability = plugin.Capability<Service>

scale.capability = plugin.capability<<Service>> { name = 'lunette/scale', version = 1 }

return scale
