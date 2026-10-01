-- The arc layout's geometry: panels face the centre from a circle of `radius` at its height, at least
-- `step` radians apart and further when wide enough to meet, with `gap` metres between edges. An arc wider
-- than `span` shrinks every separation by one factor, and may then overlap.

local geometry = {}

export type Tuning = {
  read radius: number,
  read step: number,
  read span: number,
  read gap: number,
  read center: { number },
}

-- The angle of each panel, in the order of `widths`, in radians about the
-- vertical axis, with zero straight ahead and positive to the left.
function geometry.angles(widths: { number }, tuning: Tuning): { number }
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

-- The pose of each panel, in the order of `widths`.
function geometry.poses(widths: { number }, tuning: Tuning): { Mat4 }
  local radius, center = tuning.radius, tuning.center
  local placed: { Mat4 } = {}
  for index, angle in ipairs(geometry.angles(widths, tuning)) do
    placed[index] = lovr.math
      .newMat4()
      :translate(center[1] - math.sin(angle) * radius, center[2], center[3] - math.cos(angle) * radius)
      :rotate(angle, 0, 1, 0)
  end
  return placed
end

-- Raises an error naming `label` and the option for a tuning the geometry
-- cannot lay out: a radius that is not positive, a step, span, or gap that is
-- negative, or a centre that is not three numbers.
function geometry.validate(tuning: Tuning, label: string): ()
  local function finite(value: number): boolean
    return value == value and value ~= math.huge and value ~= -math.huge
  end
  if not finite(tuning.radius) or tuning.radius <= 0 then
    error(string.format('plugin %s: option radius is a positive number, not %s', label, tostring(tuning.radius)), 0)
  end
  local function nonNegative(key: string, value: number): ()
    if not finite(value) or value < 0 then
      error(string.format('plugin %s: option %s is a number of at least 0, not %s', label, key, tostring(value)), 0)
    end
  end
  nonNegative('step', tuning.step)
  nonNegative('span', tuning.span)
  nonNegative('gap', tuning.gap)
  local center = tuning.center
  if #center ~= 3 then
    error(string.format('plugin %s: option center is three numbers, not %d', label, #center), 0)
  end
  for index = 1, 3 do
    if type(center[index]) ~= 'number' or not finite(center[index]) then
      error(string.format('plugin %s: option center[%d] is a finite number', label, index), 0)
    end
  end
end

return geometry
