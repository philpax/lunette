-- Ray projection maps a flat quad's plane to unbounded top-left logical coordinates.

local quad = {}

export type Quad = {
  read pose: Mat4,
  read width: number,
  read height: number,
  read pixelWidth: number,
  read pixelHeight: number,
  read backFace: boolean?,
}

local project: (Quad, vector, vector, boolean) -> (number?, number?, number?)

function quad.project(target: Quad, origin: vector, direction: vector): (number?, number?, number?)
  return project(target, origin, direction, false)
end

function quad.hit(target: Quad, origin: vector, direction: vector): (number?, number?, number?)
  return project(target, origin, direction, true)
end

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

local function inversePose(pose: Mat4): Mat4?
  if not finiteMatrix(pose) then
    return nil
  end

  -- Inversion writes in place, so copy the pose before transforming the ray.
  local inverse = lovr.math.mat4(pose):invert()
  if not finiteMatrix(inverse) then
    return nil
  end

  -- LÖVR leaves singular matrices unchanged and can overflow or underflow during inversion.
  local product = { lovr.math.mat4(inverse):mul(pose):unpack(true) }
  for index, value in product do
    local wanted = if (index - 1) % 5 == 0 then 1 else 0
    if not isFinite(value) or math.abs(value - wanted) > 1e-4 then
      return nil
    end
  end
  return inverse
end

project = function(target: Quad, origin: vector, direction: vector, bounded: boolean): (number?, number?, number?)
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

  local inverse = inversePose(target.pose)
  if not inverse then
    return nil, nil, nil
  end
  local localOriginX, localOriginY, localOriginZ = inverse:mul(originX, originY, originZ, 1)
  local localDirectionX, localDirectionY, localDirectionZ = inverse:mul(directionX, directionY, directionZ, 0)
  for _, value in { localOriginX, localOriginY, localOriginZ, localDirectionX, localDirectionY, localDirectionZ } do
    if not isFinite(value) then
      return nil, nil, nil
    end
  end

  if localDirectionZ == 0 then
    return nil, nil, nil
  end
  if localDirectionZ > 0 and not target.backFace then
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
  -- Check local bounds before pixel conversion can round an outside point onto an edge.
  if bounded and (hitX < -halfWidth or hitX > halfWidth or hitY < -halfHeight or hitY > halfHeight) then
    return nil, nil, nil
  end

  -- The quad's +y is up and a surface's +y is down.
  local logicalX = (hitX + halfWidth) / target.width * target.pixelWidth
  local logicalY = (halfHeight - hitY) / target.height * target.pixelHeight
  if not isFinite(logicalX) or not isFinite(logicalY) then
    return nil, nil, nil
  end
  return logicalX, logicalY, distance
end

return quad
