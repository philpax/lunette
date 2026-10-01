-- Pure picking and scrolling arithmetic for pointers.
--
-- These are the default pointer mapping's building blocks, exported so that a
-- `drive` hook that replaces the mapping picks and scrolls the same way.

local vocabulary = require '@lunette-contracts/vocabulary'

local picking = {}

export type Surface = vocabulary.Surface
export type Tuning = vocabulary.Tuning

-- What scrollDelta converts: a stick deflection on each axis, the frame time
-- it is scaled by, and the tuning whose dead zone and scale apply.
export type Scroll = {
  read x: number,
  read y: number,
  read dt: number?,
  read tuning: Tuning,
}

-- A deflection past the dead zone, rescaled so the response starts at zero at
-- the dead zone's edge. A nan, a dead zone of one or more, and a deflection
-- inside the dead zone answer zero.
function picking.deadZone(value: number, dead: number): number
  if value ~= value or not (dead < 1) or math.abs(value) <= dead then
    return 0
  end
  return (value < 0 and -1 or 1) * (math.abs(value) - dead) / (1 - dead)
end

-- The nearest live surface the ray hits within reach, with the hit's pixel
-- coordinates and distance, or nothing. The direction need not be unit
-- length; a zero direction hits nothing.
function picking.pick(
  surfaces: { Surface },
  origin: vector,
  direction: vector,
  reach: number
): (Surface?, number?, number?, number?)
  local length = direction:length()
  if not (length > 0) then
    return nil, nil, nil, nil
  end
  local ray = direction * (1 / length)
  local hit: Surface?, x: number?, y: number?, distance: number?
  for _, candidate in ipairs(surfaces) do
    if not candidate.dead then
      local cx, cy, cd = candidate:raycast(origin, ray)
      if cx and cy and cd and cd <= reach and (not distance or cd < distance) then
        hit, x, y, distance = candidate, cx, cy, cd
      end
    end
  end
  return hit, x, y, distance
end

-- The scroll a stick deflection gives a sink this frame, in the sink's units,
-- on each axis. The vertical axis flips: a stick pushed up scrolls up.
function picking.scrollDelta(scroll: Scroll): (number, number)
  local tuning = scroll.tuning
  local scale = tuning.scrollScale * (scroll.dt or 0)
  return picking.deadZone(scroll.x, tuning.scrollDeadZone) * scale,
    -picking.deadZone(scroll.y, tuning.scrollDeadZone) * scale
end

return picking
