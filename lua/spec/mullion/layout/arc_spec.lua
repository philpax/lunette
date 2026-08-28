-- Covers lua/mullion/layout/arc.lua.
--
-- The layout is pure geometry, so it is checked as geometry: every panel the
-- same distance from the centre, the gaps between them equal, and the middle of
-- an odd count straight ahead. The degenerate counts are here explicitly. A
-- count of zero returns the empty list before the step arithmetic. A count of
-- one spans nothing: the single panel keeps the tuning step and is at the
-- arc's midpoint. The step-shrink condition requires `count > 1`, because one
-- panel cannot exceed a span.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local arc = require '@mullion/layout/arc'
local tag = require '@mullion/tag'

local spec = suite.new 'mullion.layout.arc'

-- Every number here came out of a trigonometric function and a 4x4 multiply,
-- whose results land in the floating-point noise around the exact value.
-- Comparisons use TOLERANCE.
local TOLERANCE = 1e-5

-- A layout needs a panel's pose and `dead` flag, and nothing more. The real
-- `mullion.panel` is not required: requiring it would make these cases depend
-- on the layer-claim fake the panel specs install, and the cases do not reach
-- past those two fields. tag_spec.lua's `newPanel` makes the same choice for
-- the same reason.
local function newPanel(name)
  local panel = { name = name, dead = false, pose = lovr.math.newMat4() }

  function panel:setPose(pose)
    self.pose:set(pose)
  end

  return panel
end

-- The distance from a pose's position to the arc's centre.
local function distanceFromCenter(pose, center)
  local x, y, z = pose:getPosition()
  local dx, dy, dz = x - center[1], y - center[2], z - center[3]
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

spec('one panel sits at the arc midpoint', function()
  local placed = arc.poses(1)

  expect.equal(#placed, 1, 'the poses')
  local x, y, z = placed[1]:getPosition()
  expect.near(x, arc.TUNING.center[1], TOLERANCE, 'x')
  expect.near(y, arc.TUNING.center[2], TOLERANCE, 'y')
  expect.near(z, arc.TUNING.center[3] - arc.TUNING.radius, TOLERANCE, 'z')
end)

spec('panels are equidistant from the centre', function()
  local placed = arc.poses(5)

  for index, pose in ipairs(placed) do
    expect.near(
      distanceFromCenter(pose, arc.TUNING.center),
      arc.TUNING.radius,
      TOLERANCE,
      'the distance of panel ' .. index
    )
  end
end)

spec('panels are evenly spaced', function()
  local placed = arc.angles(6)

  local first = placed[2] - placed[1]
  for index = 3, #placed do
    expect.near(placed[index] - placed[index - 1], first, TOLERANCE, 'the gap before panel ' .. index)
  end
end)

spec('the angles are centred on straight ahead', function()
  local odd = arc.angles(5)
  expect.near(odd[3], 0, TOLERANCE, 'the middle of an odd count')

  local even = arc.angles(4)
  expect.near(even[2] + even[3], 0, TOLERANCE, 'the straddle of an even count')
end)

spec('a wide count narrows the step rather than exceeding the span', function()
  local options = { step = 0.5, span = 1.0 }

  local placed = arc.angles(9, options)
  expect.near(placed[#placed] - placed[1], options.span, TOLERANCE, 'the total span')
  -- Narrowing keeps every panel placed.
  expect.equal(#placed, 9, 'the panels placed')
end)

spec('a count that fits keeps the step', function()
  local placed = arc.angles(3, { step = 0.4, span = 10 })

  expect.near(placed[2] - placed[1], 0.4, TOLERANCE, 'the step')
end)

spec('zero panels is a no-op rather than a division by zero', function()
  expect.equal(#arc.angles(0), 0, 'the angles')
  expect.equal(#arc.poses(0), 0, 'the poses')
  expect.equal(#arc.apply {}, 0, 'the panels placed')
end)

spec('a count that is not a whole number of panels raises', function()
  expect.raises(function()
    arc.angles(2.5)
  end, 'whole number', 'a fractional count')

  expect.raises(function()
    arc.angles(-1)
  end, 'whole number', 'a negative count')
end)

spec('a panel faces back towards the centre', function()
  local placed = arc.poses(3, { step = 1.0, radius = 2, center = { 0, 0, 0 } })

  -- The panel's own +z, in world space. A `Pass:plane` quad faces +z, so this
  -- is the panel's facing direction. The check compares it with the direction
  -- from the panel to the centre.
  for index, pose in ipairs(placed) do
    -- The centre is at the origin here, so the direction from the panel back to
    -- it is its own position negated.
    local x, y, z = pose:getPosition()
    local length = math.sqrt(x * x + y * y + z * z)
    local normalX, normalY, normalZ = pose:mul(0, 0, 1, 0)
    local dot = -(normalX * x + normalY * y + normalZ * z) / length
    expect.near(dot, 1, TOLERANCE, 'the facing of panel ' .. index)
  end
end)

spec('a partial options table falls back to the tuning for the rest', function()
  local placed = arc.poses(1, { radius = 3 })

  local _, y = placed[1]:getPosition()
  expect.near(y, arc.TUNING.center[2], TOLERANCE, 'the height')
  expect.near(distanceFromCenter(placed[1], arc.TUNING.center), 3, TOLERANCE, 'the radius')
end)

spec('applying places the current tag and skips the unselected one', function()
  tag.teardown()
  local main = tag.new('main', { selected = true })
  local hidden = tag.new 'hidden'
  local first, second, unseen = newPanel 'first', newPanel 'second', newPanel 'unseen'
  main:add(first)
  main:add(second)
  hidden:add(unseen)

  local placed = arc(tag.current())

  expect.equal(#placed, 2, 'the panels placed')
  -- Untouched, so still at the origin. The arc's centre is at eye height, and
  -- a placed panel would be a metre and a half above the origin.
  local unseenX, unseenY, unseenZ = unseen.pose:getPosition()
  expect.near(unseenX, 0, TOLERANCE, 'the unselected panel x')
  expect.near(unseenY, 0, TOLERANCE, 'the unselected panel y')
  expect.near(unseenZ, 0, TOLERANCE, 'the unselected panel z')

  local firstDistance = distanceFromCenter(first.pose, arc.TUNING.center)
  expect.near(firstDistance, arc.TUNING.radius, TOLERANCE, 'the first panel distance')
  local secondDistance = distanceFromCenter(second.pose, arc.TUNING.center)
  expect.near(secondDistance, arc.TUNING.radius, TOLERANCE, 'the second panel distance')
  tag.teardown()
end)

spec('a panel on two selected tags is placed once', function()
  tag.teardown()
  local main = tag.new('main', { selected = true })
  local side = tag.new('side', { selected = true })
  local shared = newPanel 'shared'
  main:add(shared)
  side:add(shared)

  local placed = arc(tag.current())

  expect.equal(#placed, 1, 'the panels placed')
  -- One panel, so it is at the midpoint. A panel placed twice would take the
  -- second of two positions and be off to one side.
  local x = shared.pose:getPosition()
  expect.near(x, arc.TUNING.center[1], TOLERANCE, 'the shared panel x')
  tag.teardown()
end)

spec('poses are fresh matrices rather than shared ones', function()
  local placed = arc.poses(2)

  placed[1]:translate(10, 10, 10)
  local x = placed[2]:getPosition()
  expect.near(math.abs(x), arc.TUNING.radius * math.sin(arc.TUNING.step / 2), TOLERANCE, 'the second pose x')
end)

return spec
