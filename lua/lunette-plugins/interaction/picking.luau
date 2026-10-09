-- Pure picking and scrolling arithmetic, exported so a `drive` hook picks and scrolls as the default does.

local vocabulary = require '@lunette-contracts/vocabulary'

local picking = {}

export type Surface = vocabulary.Surface
export type Tuning = vocabulary.Tuning

-- A stick deflection per axis, with the frame time and tuning that scale it.
export type Scroll = {
  read x: number,
  read y: number,
  read dt: number?,
  read tuning: Tuning,
}

-- Rescales a deflection so the response starts at zero at the dead zone's edge.
function picking.deadZone(value: number, dead: number): number
  if value ~= value or not (dead < 1) or math.abs(value) <= dead then
    return 0
  end
  return (value < 0 and -1 or 1) * (math.abs(value) - dead) / (1 - dead)
end

-- The nearest live surface hit within reach. The direction need not be unit length.
function picking.pick(
  surfaces: { read [number]: Surface },
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
  for index = 1, #surfaces do
    local candidate = surfaces[index]
    if not candidate.dead then
      local cx, cy, cd = candidate:raycast(origin, ray)
      if cx and cy and cd and cd <= reach and (not distance or cd < distance) then
        hit, x, y, distance = candidate, cx, cy, cd
      end
    end
  end
  return hit, x, y, distance
end

-- The vertical axis flips, so a stick pushed up scrolls up.
function picking.scrollDelta(scroll: Scroll): (number, number)
  local tuning = scroll.tuning
  local scale = tuning.scrollScale * (scroll.dt or 0)
  return picking.deadZone(scroll.x, tuning.scrollDeadZone) * scale,
    -picking.deadZone(scroll.y, tuning.scrollDeadZone) * scale
end

return picking
