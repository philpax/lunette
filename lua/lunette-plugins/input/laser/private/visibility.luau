-- When a beam is drawn. Over another application's scene, a beam that points at nothing is clutter, so by default it
-- shows only while it is engaged with content: hovering a surface, holding a grab, or holding a button. A beam appears
-- at once and fades out, so a ray that grazes the gap between two panels does not flicker.

local visibility = {}

export type Mode = 'engaged' | 'always'

export type Frame = {
  read mode: Mode,
  -- Whether another application's scene is visible beneath the session.
  read overlaid: boolean,
  read engaged: boolean,
  -- Seconds since the previous frame, or nil when the input carries no timing.
  read dt: number?,
  -- Seconds a beam takes to fade out.
  read fadeOut: number,
}

-- The beam's next opacity from its current one. Without timing, a beam that should hide hides at once.
function visibility.step(current: number, frame: Frame): number
  if frame.mode == 'always' or not frame.overlaid or frame.engaged then
    return 1
  end
  local dt = frame.dt
  if dt == nil or frame.fadeOut <= 0 then
    return 0
  end
  return math.max(0, current - dt / frame.fadeOut)
end

return visibility
