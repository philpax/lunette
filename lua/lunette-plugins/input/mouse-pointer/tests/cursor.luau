local testing = require '@testing'
local cursor = require '../private/cursor'
local buttons = require '../private/buttons'
local expect = testing.expect

local test = testing.suite()

local LIMITS: cursor.Limits = { sensitivity = 0.002, cone = 0.7 }

local function angleFromForward(aim: cursor.Aim): number
  local _, _, z = vector.unpack(cursor.direction(aim))
  return math.acos(math.clamp(-z, -1, 1))
end

-- Movements from tiny to far past the cone, in every direction, including none.
local function movements(): { { number } }
  local result: { { number } } = { { 0, 0 } }
  for _, magnitude in { 1, 37, 350, 2000, 1e6 } do
    for step = 0, 15 do
      local angle = step * math.pi / 8 + 0.1
      result[#result + 1] = { magnitude * math.cos(angle), magnitude * math.sin(angle) }
    end
  end
  return result
end

test('the centred cursor points forward, and movement turns right and up by the sensitivity', function()
  local x, y, z = vector.unpack(cursor.direction(cursor.CENTRE))
  expect.near(x, 0, 1e-9, 'the forward x')
  expect.near(y, 0, 1e-9, 'the forward y')
  expect.near(z, -1, 1e-9, 'the forward z')
  local aim = cursor.move(cursor.CENTRE, 100, -50, LIMITS)
  expect.near(aim.yaw, 0.2, 1e-9, 'moving right turns right')
  expect.near(aim.pitch, 0.1, 1e-9, 'moving up turns up, because window y grows downward')
  local dx, dy = vector.unpack(cursor.direction(aim))
  expect.truthy(dx > 0 and dy > 0, 'the direction leans right and up')
end)

test('every movement keeps the cursor inside the cone, on the side it moved towards', function()
  for _, movement in movements() do
    local dx, dy = movement[1], movement[2]
    local aim = cursor.move(cursor.CENTRE, dx, dy, LIMITS)
    local label = `a movement of {dx}, {dy}`
    expect.truthy(angleFromForward(aim) <= LIMITS.cone + 1e-9, label .. ' stays inside the cone')
    local x, y = vector.unpack(cursor.direction(aim))
    expect.truthy(dx == 0 or math.sign(x) == math.sign(dx) or math.abs(x) < 1e-9, label .. ' keeps its horizontal side')
    expect.truthy(dy == 0 or math.sign(y) == -math.sign(dy) or math.abs(y) < 1e-9, label .. ' keeps its vertical side')
  end
end)

test('clamping is idempotent, and leaves an aim inside the cone unchanged', function()
  for _, movement in movements() do
    local raw: cursor.Aim = { yaw = movement[1] * LIMITS.sensitivity, pitch = movement[2] * LIMITS.sensitivity }
    local once = cursor.clamp(raw, LIMITS.cone)
    local twice = cursor.clamp(once, LIMITS.cone)
    local label = `an aim of {raw.yaw}, {raw.pitch}`
    expect.near(twice.yaw, once.yaw, 1e-9, label .. ' clamps to a fixed yaw')
    expect.near(twice.pitch, once.pitch, 1e-9, label .. ' clamps to a fixed pitch')
    if angleFromForward(raw) <= LIMITS.cone and math.abs(raw.yaw) <= LIMITS.cone then
      expect.near(once.yaw, raw.yaw, 1e-9, label .. ' inside the cone keeps its yaw')
      expect.near(once.pitch, raw.pitch, 1e-9, label .. ' inside the cone keeps its pitch')
    end
  end
end)

test('a movement past the edge slides along it, and moving back leaves it at once', function()
  local edge = cursor.move(cursor.CENTRE, 10000, 0, LIMITS)
  expect.near(edge.yaw, LIMITS.cone, 1e-9, 'a far movement right stops at the edge')
  expect.near(edge.pitch, 0, 1e-9, 'with no pitch')
  local back = cursor.move(edge, -10, 0, LIMITS)
  expect.near(back.yaw, LIMITS.cone - 0.02, 1e-9, 'the overshoot is not stored')
end)

test('the ray starts at the head and turns with it', function()
  local head = lovr.math.newMat4():translate(1, 1.5, 2):rotate(math.pi / 2, 0, 1, 0)
  local aim = cursor.move(cursor.CENTRE, 100, -50, LIMITS)
  local origin, direction = cursor.ray(cursor.pose(head, aim))
  local ox, oy, oz = vector.unpack(origin)
  expect.near(ox, 1, 1e-6, 'the origin x')
  expect.near(oy, 1.5, 1e-6, 'the origin y')
  expect.near(oz, 2, 1e-6, 'the origin z')
  -- A head turned a quarter left looks along -X, so the head's right is -Z.
  local lx, ly, lz = vector.unpack(cursor.direction(aim))
  local x, y, z = vector.unpack(direction)
  expect.near(x, lz, 1e-6, 'the head forward becomes world -X')
  expect.near(y, ly, 1e-6, 'the vertical component is unchanged')
  expect.near(z, -lx, 1e-6, 'the head right becomes world -Z')
end)

test('a press released before the next frame is reported down for one frame', function()
  local state = buttons.new()
  expect.equal(buttons.fromNumber(1), 'left', 'button 1')
  expect.equal(buttons.fromNumber(2), 'right', 'button 2')
  expect.equal(buttons.fromNumber(3), 'middle', 'button 3')
  expect.equal(buttons.fromNumber(4), nil, 'an unmapped button')
  buttons.press(state, 'left')
  buttons.release(state, 'left')
  expect.equal(buttons.sample(state).left, true, 'the quick click is down for its frame')
  expect.equal(buttons.sample(state).left, nil, 'and up on the next')
  buttons.press(state, 'right')
  expect.equal(buttons.sample(state).right, true, 'a held button is down')
  expect.equal(buttons.sample(state).right, true, 'until it is released')
  buttons.release(state, 'right')
  expect.equal(buttons.sample(state).right, nil, 'a release is up on the next frame')
end)

return test
