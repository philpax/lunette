local testing = require '@testing'
local quad = require '@lunette-contracts/quad'

local expect = testing.expect
local test = testing.suite()

type Target = { pose: Mat4, width: number, height: number, pixelWidth: number, pixelHeight: number, backFace: boolean? }

local function newTarget(): Target
  return {
    pose = lovr.math.newMat4(),
    width = 2,
    height = 4,
    pixelWidth = 800,
    pixelHeight = 600,
  }
end

-- Keep the table-based validation as an independent oracle for scalar validation.
local function referenceProject(
  target: quad.Quad,
  origin: vector,
  direction: vector,
  bounded: boolean
): (number?, number?, number?)
  local function isFinite(value: number): boolean
    return value == value and math.abs(value) < math.huge
  end
  local function finiteMatrix(pose: Mat4): boolean
    for _, value in { pose:unpack(true) } do
      if not isFinite(value) then
        return false
      end
    end
    return true
  end
  for _, dimension in { target.width, target.height, target.pixelWidth, target.pixelHeight } do
    if not isFinite(dimension) or dimension <= 0 then
      return nil, nil, nil
    end
  end
  local originX, originY, originZ = origin:unpack()
  local directionX, directionY, directionZ = direction:unpack()
  for _, value in { originX, originY, originZ, directionX, directionY, directionZ } do
    if not isFinite(value) then
      return nil, nil, nil
    end
  end
  if not finiteMatrix(target.pose) then
    return nil, nil, nil
  end
  local inverse = lovr.math.mat4(target.pose):invert()
  if not finiteMatrix(inverse) then
    return nil, nil, nil
  end
  for index, value in { lovr.math.mat4(inverse):mul(target.pose):unpack(true) } do
    local wanted = if (index - 1) % 5 == 0 then 1 else 0
    if not isFinite(value) or math.abs(value - wanted) > 1e-4 then
      return nil, nil, nil
    end
  end
  local localOriginX, localOriginY, localOriginZ = inverse:mul(originX, originY, originZ, 1)
  local localDirectionX, localDirectionY, localDirectionZ = inverse:mul(directionX, directionY, directionZ, 0)
  for _, value in { localOriginX, localOriginY, localOriginZ, localDirectionX, localDirectionY, localDirectionZ } do
    if not isFinite(value) then
      return nil, nil, nil
    end
  end
  if localDirectionZ == 0 or (localDirectionZ > 0 and not target.backFace) then
    return nil, nil, nil
  end
  local distance = -localOriginZ / localDirectionZ
  if not isFinite(distance) or distance <= 0 then
    return nil, nil, nil
  end
  local hitX = localOriginX + distance * localDirectionX
  local hitY = localOriginY + distance * localDirectionY
  if not isFinite(hitX) or not isFinite(hitY) then
    return nil, nil, nil
  end
  local halfWidth, halfHeight = target.width / 2, target.height / 2
  if bounded and (hitX < -halfWidth or hitX > halfWidth or hitY < -halfHeight or hitY > halfHeight) then
    return nil, nil, nil
  end
  local logicalX = (hitX + halfWidth) / target.width * target.pixelWidth
  local logicalY = (halfHeight - hitY) / target.height * target.pixelHeight
  if not isFinite(logicalX) or not isFinite(logicalY) then
    return nil, nil, nil
  end
  return logicalX, logicalY, distance
end

local function expectReference(target: quad.Quad, origin: vector, direction: vector, context: string)
  for _, name in { 'hit', 'project' } do
    local wantedX, wantedY, wantedDistance = referenceProject(target, origin, direction, name == 'hit')
    local x, y, distance = quad[name](target, origin, direction)
    expect.equal(x, wantedX, context .. ', ' .. name .. ' oracle x')
    expect.equal(y, wantedY, context .. ', ' .. name .. ' oracle y')
    expect.equal(distance, wantedDistance, context .. ', ' .. name .. ' oracle distance')
  end
end

local function expectRejected(target: quad.Quad, origin: vector, direction: vector, context: string)
  expectReference(target, origin, direction, context)
  for _, name in { 'hit', 'project' } do
    local x, y, distance = quad[name](target, origin, direction)
    expect.equal(x, nil, context .. ', ' .. name .. ' x')
    expect.equal(y, nil, context .. ', ' .. name .. ' y')
    expect.equal(distance, nil, context .. ', ' .. name .. ' distance')
  end
end

local function expectUnchanged(pose: Mat4, before: { number }, context: string)
  local after = { pose:unpack(true) }
  for index = 1, 16 do
    local same = after[index] == before[index] or (after[index] ~= after[index] and before[index] ~= before[index])
    expect.truthy(same, context .. ', element ' .. index)
  end
end

test('projection and bounded hits agree at the center and at inclusive corners', function()
  local target = newTarget()
  local points = {
    { 0, 0, 400, 300 },
    { -1, 2, 0, 0 },
    { 1, -2, 800, 600 },
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

test('nonpositive dimensions and nonfinite dimensions, ray components, or pose elements reject both forms', function()
  for _, field in { 'width', 'height', 'pixelWidth', 'pixelHeight' } do
    for index, value in { 0, -1, 0 / 0, math.huge, -math.huge } do
      local target = newTarget()
      target[field] = value
      expectRejected(target, vector.pack(0, 0, 1), vector.pack(0, 0, -1), field .. ' value ' .. index)
    end
  end
  for component = 1, 3 do
    for index, value in { 0 / 0, math.huge, -math.huge } do
      local origin = { 0, 0, 1 }
      origin[component] = value
      local context = 'component ' .. component .. ' value ' .. index
      expectRejected(newTarget(), vector.pack(table.unpack(origin)), vector.pack(0, 0, -1), 'origin ' .. context)
      local direction = { 0, 0, -1 }
      direction[component] = value
      expectRejected(newTarget(), vector.pack(0, 0, 1), vector.pack(table.unpack(direction)), 'direction ' .. context)
    end
  end
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

test('parallel zero backward and onplane rays have no forward intersection', function()
  local rays = {
    { vector.pack(0, 0, 1), vector.pack(1, 0, 0) },
    { vector.pack(0, 0, 1), vector.pack(0, 0, 0) },
    { vector.pack(0, 0, -1), vector.pack(0, 0, -1) },
    { vector.pack(0, 0, 0), vector.pack(0, 0, -1) },
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
  target.backFace = true
  for _, name in { 'project', 'hit' } do
    local x, y, distance = quad[name](target, origin, direction)
    expect.equal(x, 600, name .. ' backface x')
    expect.equal(y, 150, name .. ' backface y')
    expect.equal(distance, 2, name .. ' backface distance')
  end
end)

test('singular poses reject rays even when native inversion leaves them unchanged', function()
  local poses = {
    lovr.math.newMat4():scale(0, 1, 1),
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

test('inversion overflow and underflow reject finite poses without mutating them', function()
  for _, scale in { 1e-20, 1e20 } do
    local target = newTarget()
    target.pose:scale(scale, scale, scale)
    local before = { target.pose:unpack(true) }
    expectRejected(target, vector.pack(0, 0, 1), vector.pack(0, 0, -1), 'scale ' .. scale)
    expectUnchanged(target.pose, before, 'the finite pose')
  end
end)

test('finite rays that overflow after transformation reject both forms', function()
  for component = 1, 3 do
    local target = newTarget()
    target.pose:scale(
      if component == 1 then 1e-10 else 1,
      if component == 2 then 1e-10 else 1,
      if component == 3 then 1e-10 else 1
    )
    local origin = { 0, 0, 1 }
    origin[component] = 1e30
    local context = 'origin component ' .. component
    expectRejected(target, vector.pack(table.unpack(origin)), vector.pack(0, 0, -1), context)
    local direction = { 0, 0, -1 }
    direction[component] = if component == 3 then -1e30 else 1e30
    expectRejected(
      target,
      vector.pack(0, 0, 1),
      vector.pack(table.unpack(direction)),
      'direction component ' .. component
    )
  end
end)

test('logical coordinate overflow rejects both forms', function()
  local target = newTarget()
  target.width = 1e-310
  expectRejected(target, vector.pack(0.5, 0, 1), vector.pack(0, 0, -1), 'logical x overflow')
  target = newTarget()
  target.height = 1e-310
  expectRejected(target, vector.pack(0, 0.5, 1), vector.pack(0, 0, -1), 'logical y overflow')
end)

test('repeated calls observe in-place pose edits and leave each pose unchanged', function()
  local target = newTarget()
  local pose = target.pose
  local origin, direction = vector.pack(0, 0, 3), vector.pack(0, 0, -1)
  local states = {
    { 0, 0, 0, 1, 400, 300, 3 },
    { 0.5, 1, -2, 1, 200, 450, 5 },
    { -0.5, -1, 1, 1, 600, 150, 2 },
    { 0, 0, 0, 0 },
    { 0, 0, 0, 1, 400, 300, 3 },
  }
  for index, state in states do
    pose:identity():translate(state[1], state[2], state[3]):scale(state[4], 1, 1)
    local before = { pose:unpack(true) }
    for repetition = 1, 3 do
      local context = 'state ' .. index .. ' repetition ' .. repetition
      expectReference(target, origin, direction, context)
      for _, name in { 'hit', 'project' } do
        local x, y, distance = quad[name](target, origin, direction)
        expect.equal(x, state[5], context .. ', ' .. name .. ' x')
        expect.equal(y, state[6], context .. ', ' .. name .. ' y')
        expect.equal(distance, state[7], context .. ', ' .. name .. ' distance')
        expect.equal(target.pose, pose, 'the target keeps the same matrix')
        expectUnchanged(pose, before, context .. ' pose')
      end
    end
  end
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
    expectReference(target, origin, direction, 'case ' .. case)
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
