local testing = require '@testing'
local quad = require '@lunette-contracts/quad'

local expect = testing.expect
local test = testing.suite()

local function newTarget()
  return {
    pose = lovr.math.newMat4(),
    width = 2,
    height = 4,
    pixelWidth = 800,
    pixelHeight = 600,
  }
end

local function expectRejected(target, origin, direction, context)
  for _, name in { 'hit', 'project' } do
    local x, y, distance = quad[name](target, origin, direction)
    expect.equal(x, nil, context .. ', ' .. name .. ' x')
    expect.equal(y, nil, context .. ', ' .. name .. ' y')
    expect.equal(distance, nil, context .. ', ' .. name .. ' distance')
  end
end

local function expectUnchanged(pose, before, context)
  local after = { pose:unpack(true) }
  for index = 1, 16 do
    local same = after[index] == before[index] or (after[index] ~= after[index] and before[index] ~= before[index])
    expect.truthy(same, context .. ', element ' .. index)
  end
end

test('projection and bounded hits agree at the center and every inclusive edge', function()
  local target = newTarget()
  local points = {
    { 0, 0, 400, 300 },
    { -1, 2, 0, 0 },
    { 1, 2, 800, 0 },
    { -1, -2, 0, 600 },
    { 1, -2, 800, 600 },
    { -1, 0, 0, 300 },
    { 1, 0, 800, 300 },
    { 0, 2, 400, 0 },
    { 0, -2, 400, 600 },
  }
  for index, point in points do
    local origin = vector.pack(point[1], point[2], 3)
    local direction = vector.pack(0, 0, -1)
    local x, y, distance = quad.project(target, origin, direction)
    local hitX, hitY, hitDistance = quad.hit(target, origin, direction)
    expect.equal(x, point[3], 'point ' .. index .. ' x')
    expect.equal(y, point[4], 'point ' .. index .. ' y')
    expect.equal(distance, 3, 'point ' .. index .. ' distance')
    expect.equal(hitX, x, 'point ' .. index .. ' bounded x')
    expect.equal(hitY, y, 'point ' .. index .. ' bounded y')
    expect.equal(hitDistance, distance, 'point ' .. index .. ' bounded distance')
  end
end)

test('projection continues beyond each edge while bounded hits reject it', function()
  local target = newTarget()
  local points = {
    { -1.25, 0, -100, 300 },
    { 1.25, 0, 900, 300 },
    { 0, 2.5, 400, -75 },
    { 0, -2.5, 400, 675 },
    { 3, 6, 1600, -600 },
  }
  for index, point in points do
    local origin = vector.pack(point[1], point[2], 2)
    local direction = vector.pack(0, 0, -1)
    local x, y, distance = quad.project(target, origin, direction)
    expect.equal(x, point[3], 'point ' .. index .. ' projected x')
    expect.equal(y, point[4], 'point ' .. index .. ' projected y')
    expect.equal(distance, 2, 'point ' .. index .. ' distance')
    local hitX, hitY, hitDistance = quad.hit(target, origin, direction)
    expect.equal(hitX, nil, 'point ' .. index .. ' bounded x')
    expect.equal(hitY, nil, 'point ' .. index .. ' bounded y')
    expect.equal(hitDistance, nil, 'point ' .. index .. ' bounded distance')
  end
end)

test('bounded hits reject a point just outside an edge even when logical rounding reaches the boundary', function()
  local target = newTarget()
  local origin = vector.pack(1, 0, 1)
  local direction = vector.pack(2 ^ -52, 0, -1)
  local x, y, distance = quad.project(target, origin, direction)
  expect.equal(x, 800, 'the rounded logical x')
  expect.equal(y, 300, 'the logical y')
  expect.equal(distance, 1, 'the ray parameter')
  local hitX, hitY, hitDistance = quad.hit(target, origin, direction)
  expect.equal(hitX, nil, 'the bounded x outside the local edge')
  expect.equal(hitY, nil, 'the bounded y outside the local edge')
  expect.equal(hitDistance, nil, 'the bounded ray parameter outside the local edge')
end)

test('an oblique nonunit ray keeps its original ray parameter', function()
  local target = newTarget()
  local origin = vector.pack(0, 0, 4)
  local direction = vector.pack(0.25, 0.5, -2)
  for _, name in { 'project', 'hit' } do
    local x, y, distance = quad[name](target, origin, direction)
    expect.equal(x, 600, name .. ' x')
    expect.equal(y, 150, name .. ' y')
    expect.equal(distance, 2, name .. ' distance')
  end
end)

test('nonpositive and nonfinite dimensions reject both intersection forms', function()
  for _, field in { 'width', 'height', 'pixelWidth', 'pixelHeight' } do
    for index, value in { 0, -1, 0 / 0, math.huge, -math.huge } do
      local target = newTarget()
      target[field] = value
      expectRejected(target, vector.pack(0, 0, 1), vector.pack(0, 0, -1), field .. ' value ' .. index)
    end
  end
end)

test('parallel zero backward and onplane rays have no forward intersection', function()
  local rays = {
    { vector.pack(0, 0, 1), vector.pack(1, 0, 0) },
    { vector.pack(0, 0, 1), vector.pack(0, 0, 0) },
    { vector.pack(0, 0, -1), vector.pack(0, 0, -1) },
    { vector.pack(0, 0, 1), vector.pack(0, 0, 1) },
    { vector.pack(0, 0, 0), vector.pack(0, 0, -1) },
    { vector.pack(0, 0, 0), vector.pack(0, 0, 1) },
  }
  local target = newTarget()
  target.backFace = true
  for index, ray in rays do
    expectRejected(target, ray[1], ray[2], 'ray ' .. index)
  end
end)

test('backface intersections require an explicit optin', function()
  local target = newTarget()
  local origin = vector.pack(0.5, 1, -2)
  local direction = vector.pack(0, 0, 1)
  expectRejected(target, origin, direction, 'the default front face')
  target.backFace = false
  expectRejected(target, origin, direction, 'the explicit front face')
  target.backFace = true
  for _, name in { 'project', 'hit' } do
    local x, y, distance = quad[name](target, origin, direction)
    expect.equal(x, 600, name .. ' backface x')
    expect.equal(y, 150, name .. ' backface y')
    expect.equal(distance, 2, name .. ' backface distance')
  end
end)

test('nonfinite components anywhere in either ray vector are rejected', function()
  for component = 1, 3 do
    for index, value in { 0 / 0, math.huge, -math.huge } do
      local origin = { 0, 0, 1 }
      origin[component] = value
      expectRejected(newTarget(), vector.pack(table.unpack(origin)), vector.pack(0, 0, -1), 'origin ' .. index)
      local direction = { 0, 0, -1 }
      direction[component] = value
      expectRejected(newTarget(), vector.pack(0, 0, 1), vector.pack(table.unpack(direction)), 'direction ' .. index)
    end
  end
end)

test('a nonfinite element anywhere in the pose rejects the ray without changing the pose', function()
  for element = 1, 16 do
    for index, value in { 0 / 0, math.huge, -math.huge } do
      local target = newTarget()
      local elements = { target.pose:unpack(true) }
      elements[element] = value
      target.pose:set(table.unpack(elements))
      local before = { target.pose:unpack(true) }
      expectRejected(target, vector.pack(0, 0, 1), vector.pack(0, 0, -1), 'element ' .. element .. ' value ' .. index)
      expectUnchanged(target.pose, before, 'the rejected pose')
    end
  end
end)

test('singular poses reject rays even when native inversion leaves them unchanged', function()
  local poses = {
    lovr.math.newMat4():scale(0, 1, 1),
    lovr.math.newMat4():scale(1, 0, 1),
    lovr.math.newMat4():scale(1, 1, 0),
    lovr.math.newMat4(0),
    lovr.math.newMat4(1, 2, 3, 0, 1, 2, 3, 0, 0, 0, 1, 0, 0, 0, 0, 1),
  }
  for index, pose in poses do
    local target = newTarget()
    target.pose = pose
    local before = { pose:unpack(true) }
    expectRejected(target, vector.pack(0, 0, 1), vector.pack(0, 0, -1), 'singular pose ' .. index)
    expectUnchanged(pose, before, 'the singular pose')
  end
end)

test('finite poses whose native inversion overflows or underflows are rejected', function()
  for index, scale in { 1e20, 1e-20 } do
    local target = newTarget()
    target.pose:scale(scale, scale, scale)
    local before = { target.pose:unpack(true) }
    expectRejected(target, vector.pack(0, 0, 1), vector.pack(0, 0, -1), 'extreme scale ' .. index)
    expectUnchanged(target.pose, before, 'the extreme pose')
  end
end)

test('finite inputs that overflow transformed rays or logical coordinates are rejected', function()
  local target = newTarget()
  target.pose:scale(0.01, 1, 1)
  expectRejected(target, vector.pack(1e38, 0, 1), vector.pack(0, 0, -1), 'the transformed origin')
  expectRejected(target, vector.pack(0, 0, 1), vector.pack(1e38, 0, -1), 'the transformed direction')

  target = newTarget()
  target.pixelWidth = 1e308
  expectRejected(target, vector.pack(4, 0, 1), vector.pack(0, 0, -1), 'the logical x overflow')
  target = newTarget()
  target.pixelHeight = 1e308
  expectRejected(target, vector.pack(0, -8, 1), vector.pack(0, 0, -1), 'the logical y overflow')
  target = newTarget()
  target.width = 1e-308
  expectRejected(target, vector.pack(4, 0, 1), vector.pack(0, 0, -1), 'the dimension ratio overflow')
end)

test('a tiny nonzero forward direction remains a valid finite intersection', function()
  local target = newTarget()
  local direction = vector.pack(0, 0, -1e-30)
  local x, y, distance = quad.project(target, vector.pack(0, 0, 1), direction)
  expect.equal(x, 400, 'the projected x')
  expect.equal(y, 300, 'the projected y')
  expect.near(distance, -1 / direction.z, 1e24, 'the finite ray parameter')
  local hitX, hitY, hitDistance = quad.hit(target, vector.pack(0, 0, 1), direction)
  expect.equal(hitX, x, 'the bounded x')
  expect.equal(hitY, y, 'the bounded y')
  expect.equal(hitDistance, distance, 'the bounded ray parameter')
end)

test('deterministic affine rays recover known plane points and preserve every pose element', function()
  local random = lovr.math.newRandomGenerator(20261003)
  for case = 1, 200 do
    local target = newTarget()
    target.width = 0.5 + random:random() * 4
    target.height = 0.5 + random:random() * 4
    target.pixelWidth = 100 + random:random() * 900
    target.pixelHeight = 100 + random:random() * 900
    local reflect = if case % 5 == 0 then -1 else 1
    target.pose
      :translate((random:random() - 0.5) * 10, (random:random() - 0.5) * 10, (random:random() - 0.5) * 10)
      :rotate(random:random() * math.pi * 2, 0.2, 0.7, 0.4)
      :scale(reflect * (0.5 + random:random() * 2), 0.5 + random:random() * 2, 0.5 + random:random() * 2)
      :rotate(random:random(), 0, 0, 1)
    local outside = case % 2 == 0
    local fractionX = if outside then -0.2 - random:random() else 0.1 + random:random() * 0.8
    local fractionY = 0.1 + random:random() * 0.8
    local pointX = (fractionX - 0.5) * target.width
    local pointY = (0.5 - fractionY) * target.height
    target.backFace = case % 3 == 0
    local directionX = random:random() - 0.5
    local directionY = random:random() - 0.5
    local directionZ = (if target.backFace then 1 else -1) * (0.5 + random:random())
    local wantedDistance = 0.5 + random:random() * 5
    local originX, originY, originZ = target.pose:mul(
      pointX - directionX * wantedDistance,
      pointY - directionY * wantedDistance,
      -directionZ * wantedDistance,
      1
    )
    local rayX, rayY, rayZ = target.pose:mul(directionX, directionY, directionZ, 0)
    local origin = vector.pack(originX, originY, originZ)
    local direction = vector.pack(rayX, rayY, rayZ)
    local before = { target.pose:unpack(true) }
    local x, y, distance = quad.project(target, origin, direction)
    expect.near(x, fractionX * target.pixelWidth, 0.02, 'case ' .. case .. ' projected x')
    expect.near(y, fractionY * target.pixelHeight, 0.02, 'case ' .. case .. ' projected y')
    expect.near(distance, wantedDistance, 1e-4, 'case ' .. case .. ' ray parameter')
    local hitX, hitY, hitDistance = quad.hit(target, origin, direction)
    if outside then
      expect.equal(hitX, nil, 'case ' .. case .. ' bounded x')
      expect.equal(hitY, nil, 'case ' .. case .. ' bounded y')
      expect.equal(hitDistance, nil, 'case ' .. case .. ' bounded distance')
    else
      expect.equal(hitX, x, 'case ' .. case .. ' bounded x')
      expect.equal(hitY, y, 'case ' .. case .. ' bounded y')
      expect.equal(hitDistance, distance, 'case ' .. case .. ' bounded distance')
    end
    expectUnchanged(target.pose, before, 'case ' .. case .. ' pose')
  end
end)

return test
