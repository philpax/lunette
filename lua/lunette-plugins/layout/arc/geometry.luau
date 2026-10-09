-- Panels face the centre from a circle. Adjacent panels keep the minimum angular step and edge gap when
-- they fit within the span; larger layouts scale separations uniformly and may overlap.

local geometry = {}

export type Tuning = {
  read radius: number,
  read step: number,
  read span: number,
  read gap: number,
  read center: vector,
}

-- Returns panel angles in width order. Zero faces forward, and positive angles turn left.
function geometry.angles(widths: { read [number]: number }, tuning: Tuning): { number }
  local count = #widths
  local placed: { number } = {}
  if count == 0 then
    return placed
  end
  local radius = tuning.radius
  local separations: { number } = {}
  local total = 0
  for index = 1, count - 1 do
    local needed = math.atan(widths[index] / 2 / radius)
      + math.atan(widths[index + 1] / 2 / radius)
      + tuning.gap / radius
    separations[index] = math.max(tuning.step, needed)
    total += separations[index]
  end
  if total > tuning.span then
    local scale = tuning.span / total
    for index = 1, count - 1 do
      separations[index] *= scale
    end
    total = tuning.span
  end
  placed[1] = -total / 2
  for index = 2, count do
    placed[index] = placed[index - 1] + separations[index - 1]
  end
  return placed
end

function geometry.poses(widths: { read [number]: number }, tuning: Tuning): { Mat4 }
  local radius, center = tuning.radius, tuning.center
  local placed: { Mat4 } = {}
  for index, angle in ipairs(geometry.angles(widths, tuning)) do
    placed[index] = lovr.math
      .newMat4()
      :translate(center + vector.pack(-math.sin(angle) * radius, 0, -math.cos(angle) * radius))
      :rotate(angle, 0, 1, 0)
  end
  return placed
end

return geometry
