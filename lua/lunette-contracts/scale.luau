-- The output scale contract.
--
-- An output's scale is what its clients render at, so raising it as the user
-- approaches a panel makes the client sharper. A client re-lays-out and
-- reallocates its buffers whenever its scale changes, so the scale moves
-- between discrete steps with hysteresis and never continuously;
-- docs/dev/compositor.md states the policy. The service hands out choosers. A
-- chooser belongs to one output, receives the distance in metres to the
-- nearest panel the output's clients are shown on, and answers the step to set.
-- It reads no headset, clock, or panel itself, and holds no native resource,
-- so a chooser is not owner-scoped.

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
