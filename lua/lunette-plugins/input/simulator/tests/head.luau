local testing = require '@testing'
local head = require '../private/head'
local expect = testing.expect

local test = testing.suite()

local ORIGIN = vector.pack(0, 1.7, 0)
local SPEEDS: head.Speeds = { speed = 3, sprintSpeed = 15, walkSpeed = 0.5 }
local NONE: head.Keys = {
  forward = false,
  backward = false,
  left = false,
  right = false,
  up = false,
  down = false,
  sprint = false,
  walk = false,
}

local function with(changes: { [string]: boolean }): head.Keys
  local keys = table.clone(NONE) :: any
  for key, value in changes do
    keys[key] = value
  end
  return keys
end

local function near(actual: vector, wanted: vector, context: string): ()
  local ax, ay, az = vector.unpack(actual)
  local wx, wy, wz = vector.unpack(wanted)
  expect.near(ax, wx, 1e-5, context .. ' x')
  expect.near(ay, wy, 1e-5, context .. ' y')
  expect.near(az, wz, 1e-5, context .. ' z')
end

-- The forward direction the orientation sends -Z to, through the angle and axis the headset receives.
local function forward(state: head.State): vector
  local angle, ax, ay, az = head.angleAxis(state)
  local v = vector.pack(0, 0, -1)
  local axis = vector.pack(ax, ay, az)
  local c, s = math.cos(angle), math.sin(angle)
  return v * c + vector.cross(axis, v) * s + axis * vector.dot(axis, v) * (1 - c)
end

test('a pose round-trips through yaw and pitch for directions all around the head', function()
  for yawStep = -7, 8 do
    for _, pitch in { -1.4, -0.6, 0, 0.3, 1.2 } do
      local yaw = yawStep * math.pi / 8
      local direction = vector.pack(-math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch))
      local state = head.fromPose(ORIGIN, direction * 3)
      near(head.rotate(state, vector.pack(0, 0, -1)), direction, `the forward at {yaw}, {pitch}`)
      near(forward(state), direction, `the orientation's forward at {yaw}, {pitch}`)
    end
  end
end)

test('a drag keeps the scene under the cursor, and pitch stops at straight up and down', function()
  local view: head.View = { left = 0.7, right = 0.7, up = 0.6, down = 0.6 }
  local state = head.fromPose(ORIGIN, vector.pack(0, 0, -1))
  -- Dragging from the centre to the right edge pulls the edge's direction to the centre: the head turns left by the
  -- view's left half-angle, so what was at the centre is now at the right edge.
  local yaw, pitch = head.drag(500, 300, 1000, 300, 1000, 600, view, 1)
  expect.near(yaw, 0.7, 1e-9, 'the turn is the angle the cursor crossed')
  expect.near(pitch, 0, 1e-9, 'a level drag does not pitch')
  local turned = head.turn(state, yaw, pitch)
  local x = vector.unpack(head.rotate(turned, vector.pack(0, 0, -1)))
  expect.truthy(x < 0, 'a drag right turns the view left')
  local _, down = head.drag(500, 300, 500, 600, 1000, 600, view, 0.5)
  expect.near(down, 0.3, 1e-9, 'a drag down looks up, scaled')
  expect.near(head.turn(state, 0, 10).pitch, math.pi / 2, 1e-9, 'straight up')
  expect.near(head.turn(state, 0, -10).pitch, -math.pi / 2, 1e-9, 'straight down')
end)

test('keys move along the view at the selected speed, and opposite keys cancel', function()
  local state = head.turn(head.fromPose(ORIGIN, vector.pack(0, 0, -1)), 0, 0.4)
  expect.equal(head.move(state, NONE, SPEEDS, 1), state, 'no keys, no move')
  expect.equal(head.move(state, with { forward = true, backward = true }, SPEEDS, 1), state, 'opposites cancel')
  local moved = head.move(state, with { forward = true }, SPEEDS, 0.5)
  near(moved.position - ORIGIN, head.rotate(state, vector.pack(0, 0, -1.5)), 'forward along the pitched view')
  local diagonal = head.move(state, with { forward = true, right = true }, SPEEDS, 1)
  expect.near(vector.magnitude(diagonal.position - ORIGIN), 3, 1e-5, 'a diagonal is no faster')
  local sprint = head.move(state, with { up = true, sprint = true }, SPEEDS, 1)
  expect.near(vector.magnitude(sprint.position - ORIGIN), 15, 1e-5, 'shift sprints')
  local walk = head.move(state, with { down = true, walk = true }, SPEEDS, 1)
  expect.near(vector.magnitude(walk.position - ORIGIN), 0.5, 1e-5, 'control walks')
end)

test('the shown view follows its target at any frame rate, and a zero rate follows at once', function()
  local fine = 0
  for _ = 1, 10 do
    fine = head.follow(fine, 1, 30, 0.01)
  end
  local coarse = head.follow(0, 1, 30, 0.1)
  expect.near(fine, coarse, 1e-9, 'ten small steps match one large one')
  expect.truthy(coarse > 0.9 and coarse < 1, 'most of the way there')
  expect.equal(head.follow(0, 1, 0, 0.01), 1, 'a zero rate follows at once')
end)

return test
