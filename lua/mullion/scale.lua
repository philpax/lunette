-- Which scale an output is set to, chosen from discrete steps with hysteresis.
--
-- docs/dev/compositor.md states the policy: the standard library uses discrete
-- scale steps with hysteresis and never adjusts continuously. This is Lua
-- policy, and it is tunable. Rust advertises `wp_fractional_scale_v1` and
-- lets Lua choose the number; mullion.scale is where the number is chosen.
--
-- Continuous adjustment is avoided. A client re-lays-out and reallocates its
-- buffers on every scale change it is told about, and some clients, GTK in
-- particular, recompute the whole widget tree. A panel whose scale tracks the
-- user's head would reallocate constantly. Slightly the wrong sharpness is
-- cheaper than that.
--
-- The ladder is `lunette.scaleSteps()`, the same one the layer pool quantises
-- a requested size against. A single ladder means a raised panel's size
-- quantises to a rung the free list already holds, so no allocation is
-- forced. Every allocation blocks on `XR_INFINITE_DURATION`. A second ladder
-- here would stay consistent with that one for as long as nobody edits
-- either.
--
-- The module is pure. Nothing here reads a headset, a clock, or a panel. A
-- chooser is handed a distance and answers with a scale, so the specs pass
-- distances toward a panel and away from it without a room to do it in.
--
-- The module starts nothing and holds no handle. A chooser is owned by
-- whatever made it, and a source reload re-runs the module and rebuilds the
-- ladder. A reload leaves nothing behind.

local lunette = require '@lunette'

local scale = {}

type Tuning = typeof(scale.TUNING)
export type Chooser = {
  tuning: Tuning,
  steps: { number },
  index: number?,
  read choose: (Chooser, number) -> (number, boolean),
  read current: (Chooser) -> number?,
  read reset: (Chooser) -> (),
}

-- Declared above the public API and defined below it, so the public surface
-- comes first in the file.
local methods = {}
local metatable = { __index = methods }
local idealScale, settle, largestAtMost

-- Everything the choice is tuned by, in one table.
--
-- A tuning pass edits this table; the numbers are not scattered through
-- functions. `mullion.pacing.TUNING` plays the same role for frame pacing. A
-- caller that needs different numbers for one output passes its
-- own table as `options.tuning`; it leaves the default in place.
scale.TUNING = {
  -- The distance in metres at which a panel is rendered at scale 1. Closer
  -- than this, the ideal scale rises in proportion; further away, it falls.
  -- A panel at twice the distance covers half as much of the user's view, so
  -- half the pixels per metre keep the same legibility.
  reference = 1.0,
  -- How far past a rung the ideal must rise for the step to be taken, as a
  -- fraction of the rung. Together with `lower` it forms the hysteresis: a
  -- band surrounds each rung, and the ideal can move inside it without
  -- changing the step.
  raise = 0.06,
  -- How far below the current rung the ideal must fall for the step to be
  -- given back, as a fraction of it. It is larger than `raise`, because
  -- dropping a step makes a panel blurrier and that is the change a user
  -- notices. Being slow to give sharpness back costs memory and nothing else.
  lower = 0.12,
  -- The closest a panel is treated as being, in metres. A distance of zero
  -- has no ideal scale, so a user who walks their head through a panel
  -- receives the top of the ladder and no error.
  nearest = 0.05,
}

-- The ladder every chooser quantises to, ascending.
--
-- Read once when the module loads, not per call. It is a constant of the
-- build, and a soft reload re-runs the module and reads it again.
scale.STEPS = lunette.scaleSteps()

-- A chooser for one output, holding the step it last settled on.
--
-- `options.tuning` replaces `scale.TUNING` for this chooser, and
-- `options.steps` replaces the ladder. The steps override exists for the
-- specs, which pass a ladder they define; a configuration has no reason to
-- replace the ladder.
--
-- The chooser starts on no step, so the first distance it receives maps
-- directly to a step. Hysteresis does not hold it back from a step no panel
-- has ever been rendered at.
function scale.newChooser(options: { steps: { number }?, tuning: Tuning? }?): Chooser
  local opts: { steps: { number }?, tuning: Tuning? } = options or {}
  local steps = (opts.steps :: { number }?) or scale.STEPS

  if type(steps) ~= 'table' or #steps == 0 then
    error('mullion.scale: a chooser needs a ladder of at least one step', 2)
  end

  -- Luau cannot verify that `setmetatable` produces a Chooser, because the
  -- methods are injected through `__index` and are not on the table itself.
  local _raw: any = setmetatable({
    tuning = (opts.tuning :: Tuning?) or scale.TUNING,
    steps = steps,
    index = nil,
  }, metatable)
  return _raw
end

-- The scale this chooser settles on for a panel `distance` metres away.
--
-- Returns the scale and whether it changed, so a caller can skip the
-- `output:setMode` call when the scale is unchanged. The compositor sends
-- nothing when the value is unchanged. A caller usually has other work to
-- skip alongside it.
function methods.choose(self: Chooser, distance: number): (number, boolean)
  local ideal = idealScale(distance, self.tuning)
  local previous = self.index

  local settled: number = settle(self.steps, previous, ideal, self.tuning)
  self.index = settled
  return self.steps[settled], settled ~= previous
end

-- The scale the chooser last settled on, or nil until a choice has been made.
function methods.current(self: Chooser): number?
  return self.index and self.steps[self.index]
end

-- Forgets the settled step, so the next choice is made without hysteresis.
--
-- A panel teleported across the room needs this. Stepping it one rung a frame
-- until the scale reaches its new distance would make the client re-render at
-- every intermediate rung.
function methods.reset(self: Chooser): ()
  self.index = nil
end

-- The scale a panel `distance` metres away would ideally be rendered at, with
-- the ladder and the hysteresis not applied.
--
-- Inverse in the distance: a panel twice as far away subtends half the angle,
-- so half the pixels per metre keep the same legibility.
function idealScale(distance: number, tuning: Tuning): number
  if type(distance) ~= 'number' or distance ~= distance then
    error('mullion.scale: a distance is a number, not a ' .. type(distance), 3)
  end

  return tuning.reference / math.max(distance, tuning.nearest)
end

-- The index the chooser settles on, given the previous index.
--
-- The chooser takes a step when the ideal has passed the next rung by the
-- raise margin and gives the step back when the ideal has fallen below the
-- current rung by the lower margin. The raise threshold lies above every rung
-- and the lower threshold below it, so a band surrounds each rung. Inside the
-- band the ideal reaches neither threshold, and a panel at a boundary stays
-- on one scale while the user breathes.
--
-- It loops, so a panel that jumps several rungs arrives where it belongs in
-- one call; a single step would move it one rung per frame.
function settle(steps: { number }, index: number?, ideal: number, tuning: Tuning): number
  if not index then
    return largestAtMost(steps, ideal)
  end
  index = math.min(math.max(index, 1), #steps)

  while index < #steps and ideal >= steps[index + 1] * (1 + tuning.raise) do
    index = index + 1
  end
  while index > 1 and ideal <= steps[index] * (1 - tuning.lower) do
    index = index - 1
  end

  return index
end

-- The index of the largest rung no greater than `ideal`, or 1 when every rung
-- is above it.
--
-- The nearest rung is not chosen, because it could request more pixels than
-- the distance warrants. The ladder ascends, so a scan from the bottom finds
-- the largest such rung.
function largestAtMost(steps: { number }, ideal: number): number
  local found = 1
  for index = 1, #steps do
    if steps[index] <= ideal then
      found = index
    end
  end
  return found
end

return scale
