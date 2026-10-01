-- The output scale contract. The service hands out choosers, each setting one output's scale in discrete
-- steps with hysteresis from the distance to its nearest panel; docs/dev/compositor.md states the policy. A
-- chooser holds no native resource, so it is not owner-scoped.

local plugin = require '@lunette-plugin'

local scale = {}

-- One output's chooser. `choose` answers the scale for a distance and
-- whether it differs from the previous answer. `current` answers the latest
-- scale, or nil before the first choice. `reset` forgets the latest step, so
-- the next choice is made without hysteresis.
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
