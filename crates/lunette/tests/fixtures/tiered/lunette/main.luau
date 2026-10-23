-- Runs a hot loop across frames and checks that every frame computes the same result.
--
-- The loop's iterations exceed the tier-up threshold in the first frame, so under tiered execution the later frames run promoted native
-- code. The interpreter computes the first frame's result, so a promotion that changed behaviour produces a different value.

local FRAMES = 30
local ITERATIONS = 20000

local function mix(seed: number, count: number): number
  local value = seed
  for index = 1, count do
    value = (value * 31 + index) % 1000003
  end
  return value
end

local frames = 0
local expected: number? = nil

function lovr.update()
  frames += 1
  local value = mix(frames % 7, ITERATIONS)
  local reference = expected
  if reference == nil then
    expected = value
  elseif (frames - 1) % 7 == 0 and value ~= reference then
    lovr.event.quit(8)
    return
  end
  if frames == FRAMES then
    lovr.event.quit(7)
  end
end
