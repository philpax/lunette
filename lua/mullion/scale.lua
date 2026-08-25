-- Which scale an output is set to, chosen from discrete steps with hysteresis.
--
-- docs/compositor.md states the policy in one line: "The standard library uses
-- discrete scale steps with hysteresis rather than continuous adjustment. This
-- is Lua policy, and it is tunable." Rust advertises `wp_fractional_scale_v1`
-- and lets Lua choose the value, and this module chooses it.
--
-- Continuous adjustment is what this policy avoids. A client re-lays-out and
-- reallocates its buffers on every scale change it is told about, and some
-- clients (GTK in particular) recompute the whole widget tree, so a panel whose
-- scale tracked the user's head would reallocate continuously. A slightly wrong
-- sharpness costs less than that.
--
-- The steps come from `lunette.scaleSteps()`, the same list the layer pool
-- quantises a requested size against. Sharing one list means raising a panel's
-- scale asks the pool for a step whose layer the free list already holds rather
-- than forcing an allocation, and every allocation blocks on
-- `XR_INFINITE_DURATION`. A second list written here would stay consistent with
-- that one only until someone edited one of them.
--
local lunette = require '@lunette'

local scale = {}

-- The shape of a tuning table, and of a chooser, for the locals that hold them.
type Tuning = typeof(scale.TUNING)
export type Chooser = {
  tuning: Tuning,
  steps: { number },
  index: number?,
  read choose: (Chooser, number) -> (number, boolean),
  read current: (Chooser) -> number?,
  read reset: (Chooser) -> (),
}

-- Declared here and defined below the public API, so the file reads
-- surface-first.
local methods = {}
local metatable = { __index = methods }
local idealScale, settle, largestAtMost

-- Everything the choice is tuned by, in one table.
--
-- Tuning is a diff to this table rather than a search through functions for a
-- number, as `mullion.interaction.TUNING` is for the feel of a pointer.
scale.TUNING = {
  -- The distance in metres at which a panel is rendered at scale 1. Closer than
  -- this the ideal scale rises in proportion, further away it falls, because a
  -- panel at twice the distance covers half as much of the user's view and needs
  -- half the pixels per metre.
  reference = 1.0,
  -- How far past the next step the ideal has to rise before the scale steps up,
  -- as a fraction of the step. Together with `lower` this is the hysteresis:
  -- the ideal can wander inside a band around each step without any change.
  raise = 0.06,
  -- How far below the current step the ideal has to fall before the scale steps
  -- down, as a fraction of the step. Larger than `raise`, because stepping down
  -- makes a panel blurrier and is the change a user notices, while being slow to
  -- give back sharpness costs only memory.
  lower = 0.12,
  -- The closest a panel is treated as being, in metres. A distance of zero has
  -- no ideal scale, and a user who walks their head through a panel should get
  -- the top of the ladder rather than an error.
  nearest = 0.05,
}

-- The ladder every chooser quantises to, ascending.
scale.STEPS = lunette.scaleSteps()

-- A chooser for one output, holding the step it last settled on.
--
-- `options.tuning` replaces `scale.TUNING` for this chooser, and `options.steps`
-- replaces the step list. The second exists so that a spec can drive a step list
-- it wrote itself, not because a configuration has a reason to use it.
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
-- already has is harmless (the compositor sends nothing when the value is
-- unchanged), but a caller usually has other work to skip alongside it.
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
-- Resetting avoids stepping through every rung after a panel moves.
function methods.reset(self: Chooser): ()
  self.index = nil
end

-- The scale a panel `distance` metres away would ideally be rendered at,
-- before quantisation to the step list and the hysteresis margins.
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
-- A step is taken only when the ideal has passed the next step by the tuning's
-- margin, and given back only when it has fallen below the current step by the
-- other margin. Because the raise threshold sits above every step and the lower
-- threshold below it, there is a band around each step inside which neither
-- fires. That band stops a panel sitting at a boundary from changing scale on
-- every small movement of the user's head.
--
-- A panel that jumps several steps reaches its destination in one call.
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

-- The index of the largest step no greater than `ideal`, or 1 when every step
-- is above it.
--
-- Down rather than to the nearest, so that a chooser never asks for more pixels
-- than the distance calls for. The step list ascends, so the search scans it.
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
