-- Which scale an output is set to, chosen from discrete steps with hysteresis.
--
-- A client reallocates on every scale change, so the scale never tracks distance continuously;
-- docs/dev/compositor.md states the policy. The ladder is `lunette.scaleSteps()`, the one the layer pool
-- quantises sizes against, so a raised panel reuses a rung the free list holds. The module is pure.

local contract = require '@lunette-contracts/scale'

local chooser = {}

export type Chooser = contract.Chooser

-- What a chooser is tuned by. `reference` is the distance in metres at which a panel renders at scale 1;
-- `raise` and `lower` are the hysteresis margins past the next rung and below the current one, as fractions
-- of the rung; and `nearest` is the closest a panel is treated as being, in metres.
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

local settle, largestAtMost

-- The default ideal scale: inverse in the distance, so legibility is constant. A distance under `nearest`
-- is treated as `nearest`, so a head inside a panel gets the top of the ladder rather than an error.
function chooser.ideal(tuning: Tuning): Ideal
  return function(distance: number): number
    return tuning.reference / math.max(distance, tuning.nearest)
  end
end

-- A chooser for one output. It starts on no step, so the first distance maps directly to a step.
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
    -- Returns the scale and whether it changed, so a caller can skip an unchanged `output:setMode`.
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
    -- For a panel that jumped, so it does not re-render at every intermediate rung.
    reset = function(_self: Chooser): ()
      index = nil
    end,
  }
end

-- The index the chooser settles on, given the previous index.
--
-- A step is taken once the ideal passes the next rung by the raise margin and given back once it falls
-- below the current rung by the lower margin, so a panel at a boundary does not flicker. It loops, so a
-- jump of several rungs settles in one call.
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

-- The index of the largest rung no greater than `ideal`, or 1 when every rung is above it. The nearest rung
-- could request more pixels than the distance warrants.
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
