-- Which scale an output is set to, chosen from discrete steps with hysteresis.
--
-- docs/compositor.md says the policy in one line: "The standard library uses
-- discrete scale steps with hysteresis rather than continuous adjustment. This
-- is Lua policy, and it is tunable." Rust advertises `wp_fractional_scale_v1`
-- and lets Lua choose the number; this is where the number is chosen.
--
-- Continuous adjustment is the thing to avoid. A client re-lays-out and
-- reallocates its buffers on every scale change it is told about, and some — GTK
-- in particular — recompute the whole widget tree, so a panel whose scale
-- tracked the user's head would spend its life reallocating. Slightly the wrong
-- sharpness is cheaper than that, every time.
--
-- The ladder is `lunette.scaleSteps()`, which is the same one the layer pool
-- quantises a requested size against. One ladder, so that raising a panel's
-- scale asks the pool for a rung the free list already holds rather than forcing
-- an allocation — and every allocation blocks on `XR_INFINITE_DURATION`. A
-- second ladder written here would be consistent with that one only for as long
-- as nobody edited either.
--
-- Pure. Nothing here reads a headset, a clock, or a panel; a chooser is handed a
-- distance and answers with a scale, so the specs drive a user walking toward a
-- panel and away from it without a room to do it in.
--
-- This module starts nothing and holds no handle, so it registers no teardown
-- hook: a chooser is owned by whatever made it, and the ladder is rebuilt when
-- this file runs. There is nothing a reload could leave behind.

local lunette = require '@lunette'

local scale = {}

-- The shape of a tuning table, and of a chooser, for the locals that hold them.
type Tuning = typeof(scale.TUNING)
type Chooser = {
  tuning: Tuning,
  steps: { number },
  index: number? | nil,
}

-- Declared here and defined below the public API, so the file reads
-- surface-first.
local methods = {}
local metatable = { __index = methods }
local idealScale, settle, largestAtMost

-- Everything the choice is tuned by, in one table.
--
-- A tuning pass is a diff to this table rather than a hunt through functions for
-- a number, as `mullion.interaction.TUNING` is for the feel of a pointer. A
-- caller wanting different numbers for one output passes its own table as
-- `options.tuning` rather than editing this one.
scale.TUNING = {
  -- The distance in metres at which a panel is rendered at scale 1. Closer than
  -- this the ideal scale rises in proportion, further away it falls, because a
  -- panel at twice the distance covers half as much of the user's view and so
  -- wants half the pixels per metre.
  reference = 1.0,
  -- How far past a rung the ideal has to climb before the step is taken, as a
  -- fraction of the rung. Together with `lower` this is the hysteresis: a rung
  -- is surrounded by a band the ideal can wander inside without anything
  -- happening.
  raise = 0.06,
  -- How far below the current rung the ideal has to fall before the step is
  -- given back, as a fraction of it. Larger than `raise`, because dropping a
  -- step makes a panel blurrier and is the change a user notices; being slow to
  -- give sharpness back costs only memory.
  lower = 0.12,
  -- The closest a panel is treated as being, in metres. A distance of zero has
  -- no ideal scale, and a user who walks their head through a panel should get
  -- the top of the ladder rather than an error.
  nearest = 0.05,
}

-- The ladder every chooser quantises to, ascending.
--
-- Read once when this file runs rather than per call. It is a constant of the
-- build, and a soft reload re-runs this file and reads it again.
scale.STEPS = lunette.scaleSteps()

-- A chooser for one output, holding the step it last settled on.
--
-- `options.tuning` replaces `scale.TUNING` for this chooser, and `options.steps`
-- replaces the ladder — the second so that a spec can drive a ladder whose rungs
-- it wrote, not because a configuration has a reason to.
--
-- The chooser starts on no step at all, so the first distance it is given picks
-- one outright rather than being held back by hysteresis from a step nothing has
-- ever been rendered at.
function scale.newChooser(options: { steps: { number }?, tuning: Tuning? }?): Chooser
  local opts: { steps: { number }?, tuning: Tuning? } = options or {}
  local steps = (opts.steps :: { number }?) or scale.STEPS

  if type(steps) ~= 'table' or #steps == 0 then
    error('mullion.scale: a chooser needs a ladder of at least one step', 2)
  end

  -- Luau cannot verify that setmetatable produces a Chooser because the
  -- methods are injected via __index rather than being on the table itself.
  local _raw: any = setmetatable({
    tuning = (opts.tuning :: Tuning?) or scale.TUNING,
    steps = steps,
    -- The index into `steps`, or nil before the first choice.
    index = nil,
  }, metatable)
  return _raw
end

-- The scale this chooser settles on for a panel `distance` metres away.
--
-- Returns the scale and whether it changed, so a caller can skip the
-- `output:setMode` when it did not. Calling `setMode` with the scale an output
-- already has is harmless — the compositor sends nothing when the value is
-- unchanged — but a caller usually has other work to skip alongside it.
function methods.choose(self: Chooser, distance: number): (number, boolean)
  local ideal = idealScale(distance, self.tuning)
  local previous = self.index

  local settled: number = settle(self.steps, previous, ideal, self.tuning)
  self.index = settled
  return self.steps[settled], settled ~= previous
end

-- The scale the chooser last settled on, or nil before the first choice.
function methods.current(self: Chooser): number?
  return self.index and self.steps[self.index]
end

-- Forgets the settled step, so the next choice is made without hysteresis.
--
-- For a panel that was moved rather than approached: teleporting one across the
-- room and then stepping it one rung a frame until it caught up would make the
-- client re-render at every rung on the way.
function methods.reset(self: Chooser): ()
  self.index = nil
end

-- The scale a panel `distance` metres away would ideally be rendered at, before
-- the ladder and the hysteresis have their say.
--
-- Inverse in the distance: a panel twice as far away subtends half the angle, so
-- the same legibility needs half the pixels per metre.
function idealScale(distance: number, tuning: Tuning): number
  if type(distance) ~= 'number' or distance ~= distance then
    error('mullion.scale: a distance is a number, not a ' .. type(distance), 3)
  end

  return tuning.reference / math.max(distance, tuning.nearest)
end

-- The index the chooser settles on, given the one it was on.
--
-- A step is taken only when the ideal has passed the rung by the tuning's
-- margin, and given back only when it has fallen below the current rung by the
-- other one. Because the raise threshold sits above every rung and the lower
-- threshold below it, there is a band around each rung inside which neither
-- fires — which is what stops a panel at a boundary flapping between two scales
-- while the user breathes.
--
-- Loops rather than steps once, so that a panel that jumped several rungs
-- arrives where it belongs in one call rather than one rung per frame.
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

-- The index of the largest rung no greater than `ideal`, or 1 when every rung is
-- above it.
--
-- Down rather than to the nearest, so that a chooser never asks for more pixels
-- than the distance called for. The ladder ascends, so this walks it.
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
