-- Covers lua/mullion/panel/raycast.lua.
--
-- The raycast spec and the panel spec share nothing. This half is arithmetic
-- over a matrix. The other half is about claims, layers, and draw calls. The
-- module under test is required directly, not through the fixture, because it
-- reaches for nothing a fake would stand in for.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local raycast = require '@mullion/panel/raycast'
local fixture = require '@spec/mullion/panel/fixture'

local spec = suite.new 'mullion.panel.raycast'

local poseAt = fixture.poseAt
local TOLERANCE = fixture.TOLERANCE

-- A quad one metre square, two metres in front of the viewer, over an 800x600
-- source. The quad is square and the pixels are 4:3. An implementation that
-- uses one axis for both cannot pass.
local function squareQuad()
  return {
    pose = poseAt(0, 0, -2),
    width = 1,
    height = 1,
    pixelWidth = 800,
    pixelHeight = 600,
  }
end

spec('a ray through the centre hits the centre pixel', function()
  local x, y, distance = raycast.hit(squareQuad(), vector.pack(0, 0, 0), vector.pack(0, 0, -1))

  expect.near(x, 400, TOLERANCE, 'x')
  expect.near(y, 300, TOLERANCE, 'y')
  expect.near(distance, 2, TOLERANCE, 'distance')
end)

spec('a ray through the top-left corner hits pixel zero', function()
  -- The quad's own top-left is at (-0.5, +0.5) in its plane. A surface's
  -- pixels start at the quad's top-left, so this is (0, 0), not (0, 600).
  local x, y = raycast.hit(squareQuad(), vector.pack(-0.5, 0.5, 0), vector.pack(0, 0, -1))

  expect.near(x, 0, TOLERANCE, 'x')
  expect.near(y, 0, TOLERANCE, 'y')
end)

spec('a ray through the bottom-right corner hits the far pixel', function()
  local x, y = raycast.hit(squareQuad(), vector.pack(0.5, -0.5, 0), vector.pack(0, 0, -1))

  expect.near(x, 800, TOLERANCE, 'x')
  expect.near(y, 600, TOLERANCE, 'y')
end)

spec('a non-square panel maps its two axes independently', function()
  local quad = {
    pose = poseAt(0, 0, -2),
    width = 2,
    height = 0.5,
    pixelWidth = 1920,
    pixelHeight = 1080,
  }

  -- A quarter of the way across and a quarter of the way down.
  local x, y = raycast.hit(quad, vector.pack(-0.5, 0.125, 0), vector.pack(0, 0, -1))

  expect.near(x, 480, TOLERANCE, 'x')
  expect.near(y, 270, TOLERANCE, 'y')
end)

spec('a ray missing the bounds hits nothing', function()
  expect.equal(raycast.hit(squareQuad(), vector.pack(0.51, 0, 0), vector.pack(0, 0, -1)), nil, 'just past the edge')
  expect.equal(raycast.hit(squareQuad(), vector.pack(0, 5, 0), vector.pack(0, 0, -1)), nil, 'far above')
end)

spec('a ray parallel to the plane hits nothing', function()
  expect.equal(raycast.hit(squareQuad(), vector.pack(0, 0, -2), vector.pack(1, 0, 0)), nil, 'along the plane')
end)

spec('a ray travelling away from the panel hits nothing', function()
  expect.equal(raycast.hit(squareQuad(), vector.pack(0, 0, 0), vector.pack(0, 0, 1)), nil, 'pointing away')
end)

spec('a ray from behind hits nothing unless the back face is asked for', function()
  local quad = squareQuad()

  expect.equal(raycast.hit(quad, vector.pack(0, 0, -4), vector.pack(0, 0, 1)), nil, 'from behind')

  quad.backFace = true
  local x, y = raycast.hit(quad, vector.pack(0, 0, -4), vector.pack(0, 0, 1))
  expect.near(x, 400, TOLERANCE, 'x with the back face allowed')
  expect.near(y, 300, TOLERANCE, 'y with the back face allowed')
end)

spec('a rotated and translated panel maps correctly', function()
  -- Rotated a quarter turn about y and moved right, so the quad faces -x. A ray
  -- travelling +x from the origin meets its centre.
  local pose = lovr.math.newMat4():translate(3, 1, 0):rotate(-math.pi / 2, 0, 1, 0)
  local quad = { pose = pose, width = 1, height = 1, pixelWidth = 800, pixelHeight = 600 }

  local x, y, distance = raycast.hit(quad, vector.pack(0, 1, 0), vector.pack(1, 0, 0))

  expect.near(x, 400, TOLERANCE, 'x')
  expect.near(y, 300, TOLERANCE, 'y')
  expect.near(distance, 3, TOLERANCE, 'distance')

  -- Offset within the rotated plane. The turn takes the quad's own +x to the
  -- world's +z. A ray a quarter-width towards +z lands right of centre, and one
  -- a quarter-height above centre lands in the upper half. Both axes move at
  -- once, so an implementation that mixes them up cannot pass.
  local offsetX, offsetY = raycast.hit(quad, vector.pack(0, 1.25, 0.25), vector.pack(1, 0, 0))
  expect.near(offsetX, 600, TOLERANCE, 'x, offset')
  expect.near(offsetY, 150, TOLERANCE, 'y, offset')
end)

spec('raycasting twice does not consume the pose', function()
  local quad = squareQuad()

  raycast.hit(quad, vector.pack(0, 0, 0), vector.pack(0, 0, -1))
  local x, y = raycast.hit(quad, vector.pack(0, 0, 0), vector.pack(0, 0, -1))

  -- The intersection inverts the pose, and `invert` writes in place. A matrix
  -- that is not copied first would be destroyed by the first call.
  expect.near(x, 400, TOLERANCE, 'x on the second call')
  expect.near(y, 300, TOLERANCE, 'y on the second call')
end)

spec('a quad with no pixels hits nothing', function()
  local quad = { pose = poseAt(0, 0, -2), width = 1, height = 1, pixelWidth = 0, pixelHeight = 0 }

  expect.equal(raycast.hit(quad, vector.pack(0, 0, 0), vector.pack(0, 0, -1)), nil, 'a sourceless quad')
end)

spec('a quad with no extent hits nothing', function()
  local quad = { pose = poseAt(0, 0, -2), width = 0, height = 1, pixelWidth = 800, pixelHeight = 600 }

  expect.equal(raycast.hit(quad, vector.pack(0, 0, 0), vector.pack(0, 0, -1)), nil, 'a quad of no width')
end)

spec('takes its ray as a pair of vectors', function()
  local x, y = raycast.hit(squareQuad(), vector.pack(0, 0, 0), vector.pack(0, 0, -1))

  expect.near(x, 400, TOLERANCE, 'x')
  expect.near(y, 300, TOLERANCE, 'y')
end)

-- `rayQuadHit` is the name docs/dev/stdlib.md gives the intersection. A
-- configuration written against `panel.rayQuadHit` breaks silently if the
-- re-export is dropped in a later split. Nothing else in the tree would
-- notice.
spec('mullion.panel re-exports it as rayQuadHit', function()
  expect.equal(fixture.panel.rayQuadHit, raycast.hit, 'the re-export')
end)

return spec
