-- Discrete output scales avoid reallocating clients for continuous distance changes.
-- The chooser uses the same ladder as the compositor layer pool. See docs/development/native/compositor.md for the policy.

local contract = require '@lunette-contracts/scale'

local chooser = {}

export type Chooser = contract.Chooser

export type Tuning = {
  read reference: number,
  read raise: number,
  read lower: number,
  read nearest: number,
}

local settle, largestAtMost

-- A chooser for one output. It starts on no step, so the first distance maps directly to a step. Scale varies
-- inversely with distance, and distances below `nearest` use that minimum distance.
function chooser.new(steps: { number }, tuning: Tuning): Chooser
  local index: number? = nil
  return table.freeze {
    choose = function(_self: Chooser, distance: number): number
      local wanted = tuning.reference / math.max(distance, tuning.nearest)
      local settled = settle(steps, index, wanted, tuning)
      index = settled
      return steps[settled]
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
  local settled = index

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
