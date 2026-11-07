local testing = require '@testing'
local facing = require '../private/facing'
local expect = testing.expect
local test = testing.suite()

local RANGE: facing.Range = { visible = 0.6, hidden = 1.05 }

-- A panel at the origin that faces +z, turned about the y axis.
local function turned(angle: number): Mat4
  return lovr.math.newMat4():rotate(angle, 0, 1, 0)
end

test('the angle is the turn between the face and the head', function()
  local head = vector.pack(0, 0, 2)
  for _, angle in { 0, 0.3, 1, math.pi / 2, 2.5, math.pi } do
    expect.near(facing.angle(turned(angle), head), angle, 1e-5, `turned by {angle}`)
  end
end)

test('the angle ignores the distance to the head and the panel position', function()
  local pose = lovr.math.newMat4():translate(1, 2, 3):rotate(0.7, 0, 1, 0)
  local near = facing.angle(pose, vector.pack(1, 2, 3.5))
  local far = facing.angle(pose, vector.pack(1, 2, 30))
  expect.near(near, 0.7, 1e-5)
  expect.near(far, 0.7, 1e-5)
end)

test('a head at the panel centre counts as facing it', function()
  expect.equal(facing.angle(turned(2), vector.pack(0, 0, 0)), 0)
end)

test('the opacity is full within the visible angle and none past the hidden one', function()
  expect.equal(facing.opacity(0, RANGE), 1)
  expect.equal(facing.opacity(RANGE.visible, RANGE), 1)
  expect.equal(facing.opacity(RANGE.hidden, RANGE), 0)
  expect.equal(facing.opacity(math.pi, RANGE), 0)
end)

test('the opacity stays within 0 and 1 and never rises as the menu turns away', function()
  local previous = math.huge
  for step = 0, 400 do
    local angle = step / 400 * math.pi
    local opacity = facing.opacity(angle, RANGE)
    expect.truthy(opacity >= 0 and opacity <= 1, `opacity at {angle} is within 0 and 1`)
    expect.truthy(opacity <= previous, `opacity at {angle} does not rise`)
    previous = opacity
  end
end)

return test
