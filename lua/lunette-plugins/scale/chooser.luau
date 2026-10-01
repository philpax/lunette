-- Which scale an output is set to, chosen from discrete steps with hysteresis.
--
-- docs/dev/compositor.md states the policy: the scale moves between discrete
-- steps with hysteresis and never adjusts continuously. Rust advertises
-- `wp_fractional_scale_v1` and lets Lua choose the number; a chooser is where
-- the number is chosen.
--
-- Continuous adjustment is avoided. A client re-lays-out and reallocates its
-- buffers on every scale change it is told about, and some clients, GTK in
-- particular, recompute the whole widget tree. A panel whose scale tracks the
-- user's head would reallocate constantly. Slightly the wrong sharpness is
-- cheaper than that.
--
-- The ladder a provider passes is `lunette.scaleSteps()`, the same one the
-- layer pool quantises a requested size against. A single ladder means a
-- raised panel's size quantises to a rung the free list already holds, so no
-- allocation is forced. Every allocation blocks on `XR_INFINITE_DURATION`.
--
-- The module is pure. Nothing here reads a headset, a clock, or a panel. A
-- chooser is handed a distance and answers with a scale, so the specs pass
-- distances toward a panel and away from it without a room to do it in. It
-- starts nothing and holds no handle: a chooser is owned by whatever made it,
-- and a source reload rebuilds it.

local contract = require '@lunette-contracts/scale'

local chooser = {}

export type Chooser = contract.Chooser

-- What a chooser is tuned by. `reference` is the distance in metres at which
-- a panel is rendered at scale 1; `raise` how far past the next rung the ideal
-- must rise for the step to be taken, and `lower` how far below the current
-- rung it must fall for the step to be given back, each as a fraction of the
-- rung; and `nearest` the closest a panel is treated as being, in metres.
export type Tuning = {
  read reference: number,
  read raise: number,
  read lower: number,
  read nearest: number,
}

-- The scale a panel `distance` metres away would ideally be rendered at,
-- before the ladder and the hysteresis are applied.
export type Ideal = (number) -> number

-- What `new` takes. `steps` is the ladder, ascending. `ideal` replaces the
-- function `chooser.ideal` answers.
export type Options = {
  read steps: { number },
  read tuning: Tuning,
  read ideal: Ideal?,
}

-- Declared above the public API and defined below it, so the public surface
-- comes first in the file.
local settle, largestAtMost

-- The default ideal scale for a tuning: inverse in the distance, because a
-- panel twice as far away subtends half the angle, so half the pixels per
-- metre keep the same legibility. A distance of zero has no ideal scale, so
-- a distance under `nearest` is treated as `nearest`, and a user who walks
-- their head through a panel receives the top of the ladder and no error.
function chooser.ideal(tuning: Tuning): Ideal
  return function(distance: number): number
    return tuning.reference / math.max(distance, tuning.nearest)
  end
end

-- A chooser for one output, holding the step it last settled on.
--
-- The chooser starts on no step, so the first distance it receives maps
-- directly to a step. Hysteresis does not hold it back from a step no panel
-- has ever been rendered at.
function chooser.new(options: Options): Chooser
  if type(options) ~= 'table' then
    error('scale: a chooser is made from a table of steps and a tuning, not a ' .. type(options), 2)
  end
  local steps, tuning = options.steps, options.tuning
  if type(steps) ~= 'table' or #steps == 0 then
    error('scale: a chooser needs a ladder of at least one step', 2)
  end
  if type(tuning) ~= 'table' then
    error('scale: a chooser needs a tuning', 2)
  end
  local ideal: Ideal = options.ideal or chooser.ideal(tuning)
  local index: number? = nil

  return table.freeze {
    -- Returns the scale and whether it changed, so a caller can skip the
    -- `output:setMode` call when the scale is unchanged.
    choose = function(_self: Chooser, distance: number): (number, boolean)
      if type(distance) ~= 'number' or distance ~= distance then
        error('scale: a distance is a number of metres, not ' .. tostring(distance), 2)
      end
      local wanted = ideal(distance)
      if type(wanted) ~= 'number' or not (wanted > 0) then
        error('scale: an ideal scale is a number above zero, not ' .. tostring(wanted), 2)
      end
      local previous = index
      local settled = settle(steps, previous, wanted, tuning)
      index = settled
      return steps[settled], settled ~= previous
    end,
    current = function(_self: Chooser): number?
      return if index then steps[index] else nil
    end,
    -- A panel teleported across the room needs this. Stepping it one rung a
    -- frame until the scale reaches its new distance would make the client
    -- re-render at every intermediate rung.
    reset = function(_self: Chooser): ()
      index = nil
    end,
  }
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
  local settled = math.min(math.max(index, 1), #steps)

  while settled < #steps and ideal >= steps[settled + 1] * (1 + tuning.raise) do
    settled += 1
  end
  while settled > 1 and ideal <= steps[settled] * (1 - tuning.lower) do
    settled -= 1
  end

  return settled
end

-- The index of the largest rung no greater than `ideal`, or 1 when every rung
-- is above it.
--
-- The nearest rung is not chosen, because it could request more pixels than
-- the distance warrants. The ladder ascends, so a scan from the bottom finds
-- the largest such rung.
function largestAtMost(steps: { number }, ideal: number): number
  local found = 1
  for position = 1, #steps do
    if steps[position] <= ideal then
      found = position
    end
  end
  return found
end

return chooser
