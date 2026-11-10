-- The shape of a panel's surface for hit testing: a plane, or a cylinder of radius 1 / |curve|, as the shaders draw
-- it. A positive curve puts the cylinder's centre on the viewer's side, so the panel bends towards the viewer; a
-- negative one puts it behind, so the panel bends away, as a bracelet wraps a wrist. The cylinder's axis lies in the
-- panel plane, turned anticlockwise from the panel's vertical by the panel's curve axis. Panel coordinates across the
-- axis are measured along the arc from the panel's centre line. The cylinder maths is shared with the native panel
-- service.

local records = require './records'
local curved = require '@lunette-plugins/graphics/curved-surface'

local shape = {}

-- The curve the panel is drawn and hit with, after the shared half-turn clamp.
function shape.curvature(panel: records.Panel): number
  return curved.curvature(panel.width, panel.height, panel.curve, panel.curveAxis)
end

function shape.surface(panel: records.Panel): curved.Surface
  return curved.surface(panel.width, panel.height, panel.curve, panel.curveAxis)
end

-- Maps a point in the panel's local frame, with the panel's centre at the origin, y up, and z towards the viewer, to
-- panel coordinates and a height above the surface along its normal.
function shape.toPanel(panel: records.Panel, x: number, y: number, z: number): (number, number, number)
  return curved.toPanel(shape.surface(panel), x, y, z)
end

-- Where a ray in the panel's local frame meets the surface: panel coordinates and the distance along the ray, or nil.
-- A bounded hit must land on the panel; an unbounded one, for a capture that has left the panel, need not.
function shape.ray(
  panel: records.Panel,
  origin: vector,
  direction: vector,
  bounded: boolean
): (number?, number?, number?)
  return curved.ray(shape.surface(panel), origin, direction, bounded)
end

-- The panel's pose with its zoom: the transform from panel-frame metres to the world.
function shape.basis(panel: records.Panel): Mat4
  local scale = panel.scale
  return lovr.math.mat4(panel.pose):scale(scale, scale, scale)
end

-- The world pose of a point on the panel at an elevation, facing out of the surface there, with the panel's zoom.
function shape.frame(panel: records.Panel, u: number, v: number, elevation: number): Mat4
  return shape.basis(panel):mul(curved.frame(shape.surface(panel), u, v, elevation))
end

-- A world ray in the panel's local frame.
function shape.localRay(panel: records.Panel, origin: vector, direction: vector): (vector, vector)
  local inverse = shape.basis(panel):invert()
  local ox, oy, oz = inverse:mul(origin.x, origin.y, origin.z)
  local tx, ty, tz = inverse:mul(origin.x + direction.x, origin.y + direction.y, origin.z + direction.z)
  return vector.pack(ox, oy, oz), vector.pack(tx - ox, ty - oy, tz - oz)
end

return shape
