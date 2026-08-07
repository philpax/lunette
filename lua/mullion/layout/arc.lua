-- The arc layout: panels on a curve around the user, facing inwards.
--
-- docs/stdlib.md's tier 3 minimum-viable line asks for one layout function that
-- arranges the current tag's panels in an arc at a comfortable radius. This is
-- that function, and it is the whole of tier 3's geometry.
--
-- Written from scratch. awesome's layouts are two-dimensional and GPL-2, so
-- there is nothing there to reimplement even if the licence allowed it: an arc
-- around a head has no tiling ancestor.
--
-- A layout is a function taking panels and assigning poses, and nothing more. A
-- layout a configuration writes is then exactly as capable as this one, which is
-- the point of a standard library that can be replaced piece by piece.
--
-- `mullion.layout.arc` is one of the two module paths docs/lua-api.md attests,
-- and it is attested as a call — `mullion.layout.arc(mullion.tag.current())` —
-- so the module is callable and `apply` is the same function under a name.
--
-- This module holds no state and starts nothing, so it registers no teardown
-- hook: there is nothing a reload could leave behind.

local tag = require 'mullion.tag'

local arc = {}

-- Declared here and defined below the public API, so the file reads
-- surface-first.
local angles

-- Everything the shape of the arc is tuned by, in one table.
--
-- Feel accounts for most of the work at this tier, so a tuning pass is a diff to
-- one table rather than a hunt through functions for a number. A caller wanting
-- a different arc for one call passes its own numbers as `options` rather than
-- editing this.
arc.TUNING = {
  -- How far the panels sit from the centre, in metres. Far enough that a panel
  -- of the default size is readable without the user leaning back.
  radius = 1.6,
  -- The angle between one panel and the next, in radians. Panels are placed at
  -- this step whatever the count, so adding one widens the arc rather than
  -- moving every other panel closer.
  step = 0.55,
  -- The widest the arc is allowed to grow, in radians. Past this the step
  -- shrinks so that the last panel is still in front of the user rather than
  -- behind them.
  span = math.pi * 1.2,
  -- Where the arc is centred: the user's head, at a standing eye height.
  center = { 0, 1.5, 0 },
}

-- The angle of each of `count` panels, in radians, centred on zero.
--
-- Zero is straight ahead. The sequence is symmetric about it, so one panel sits
-- at the arc's midpoint and two straddle it, and the step shrinks rather than
-- the arc growing past `span`.
--
-- Pure, and the whole of the layout's decision-making: `poses` turns these into
-- matrices and `apply` writes those onto panels.
function arc.angles(count, options)
  return angles(count, options)
end

-- Where `count` panels go, as an array of fresh `Mat4`s.
--
-- Each faces the centre. A quad drawn by `Pass:plane` faces +z, and a panel at
-- angle θ has its +z pointing back along the radius, so a panel is readable from
-- the middle of the arc without the caller rotating it itself.
--
-- Fresh matrices rather than temporaries: LÖVR's temporary pool is drained at
-- each frame boundary, and a caller holding a pose for longer than the frame it
-- asked for it in is an ordinary thing to do.
function arc.poses(count, options)
  options = options or arc.TUNING
  local radius = options.radius or arc.TUNING.radius
  local center = options.center or arc.TUNING.center

  local placed = {}
  for index, angle in ipairs(angles(count, options)) do
    -- The forward vector, yawed. Straight ahead is -z, as it is everywhere else
    -- in LÖVR, and a yaw of `angle` about +y takes (0, 0, -1) to
    -- (-sin, 0, -cos) — so the position and the orientation are the same
    -- rotation applied to two different things, and the panel's own +z comes out
    -- pointing back down the radius at the centre.
    placed[index] = lovr.math
      .newMat4()
      :translate(
        center[1] - math.sin(angle) * radius,
        center[2],
        center[3] - math.cos(angle) * radius
      )
      :rotate(angle, 0, 1, 0)
  end
  return placed
end

-- Arranges `target` in an arc and returns the panels it placed.
--
-- `target` is a tag, an array of tags, or an array of panels, which is what
-- `mullion.tag.panelsOf` accepts — so `arc(tag.current())` arranges every
-- selected tag's panels once each, and a tag that is not selected does not
-- participate because `current` did not return it.
--
-- Nothing to arrange is a no-op rather than an error. A configuration calling
-- this every time a window opens should not have to check first, and an empty
-- arc is a well-defined arrangement of nothing.
function arc.apply(target, options)
  local panels = tag.panelsOf(target)
  local placed = arc.poses(#panels, options)
  for index, panel in ipairs(panels) do
    panel:setPose(placed[index])
  end
  return panels
end

-- The angles, without the argument checking `arc.angles` performs on the way in.
function angles(count, options)
  if type(count) ~= 'number' or count ~= math.floor(count) or count < 0 then
    error('mullion.layout.arc: a count is a whole number of panels, not ' .. tostring(count), 3)
  end

  options = options or arc.TUNING
  local step = options.step or arc.TUNING.step
  local span = options.span or arc.TUNING.span

  local placed = {}
  if count == 0 then
    return placed
  end
  -- Guarded rather than relying on the arithmetic: one panel spans nothing, and
  -- the division below would be by zero.
  if count > 1 and step * (count - 1) > span then
    step = span / (count - 1)
  end

  -- Centred on zero: the middle of an odd count sits at the arc's midpoint, and
  -- an even count straddles it.
  local first = -step * (count - 1) / 2
  for index = 1, count do
    placed[index] = first + step * (index - 1)
  end
  return placed
end

return setmetatable(arc, {
  __call = function(_, target, options)
    return arc.apply(target, options)
  end,
})
