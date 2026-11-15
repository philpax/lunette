-- The Settings control's curvature vocabulary: degrees at the panel's surface for the eye, and the curve stored.

local uiHost = require '@lunette-contracts/ui-host'
local curved = require '@lunette-plugins/graphics/curved-surface'

local curvature = {}

-- The most a panel may bend at the control: a half turn of the surface either side of the centre line.
curvature.MAX_BEND = 180
curvature.MAX_AXIS = 180

-- The bend and axis in degrees, from the panel's shared bend. The bend is the signed angle the surface turns from the
-- centre line to the edge across the axis, so a half turn each side reads 180 and one that bends away reads -180.
function curvature.read(bend: uiHost.Bend): { bend: number, axis: number }
  local across = curved.across(bend.width, bend.height, bend.axis)
  return {
    bend = math.deg(bend.curve * across / 2),
    axis = curvature.wrapAxis(math.deg(bend.axis)),
  }
end

-- The curve that turns the surface by the given degrees from its centre line to its edge across the axis.
function curvature.curve(degrees: number, axis: number, width: number, height: number): number
  local across = curved.across(width, height, axis)
  if across <= 0 then
    return 0
  end
  return math.rad(degrees) * 2 / across
end

-- Wraps an axis into (-180, 180], so a turn past the end reads as the shortest turn back.
function curvature.wrapAxis(degrees: number): number
  local wrapped = degrees % 360
  if wrapped > 180 then
    wrapped -= 360
  elseif wrapped <= -180 then
    wrapped += 360
  end
  return wrapped
end

-- A finite number from the text and inside the range, or nil. The caller clamps an entry at its own limits.
function curvature.parse(text: string, minimum: number, maximum: number): number?
  local value = tonumber(text)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    return nil
  end
  if value < minimum or value > maximum then
    return nil
  end
  return value
end

-- A control value for display: the signed arc at one decimal.
function curvature.format(degrees: number): string
  return string.format('%.1f', degrees)
end

return curvature
