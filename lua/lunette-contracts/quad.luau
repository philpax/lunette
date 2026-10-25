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
  local m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15, m16 = pose:unpack(true)
  return isFinite(m1)
    and isFinite(m2)
    and isFinite(m3)
    and isFinite(m4)
    and isFinite(m5)
    and isFinite(m6)
    and isFinite(m7)
    and isFinite(m8)
    and isFinite(m9)
    and isFinite(m10)
    and isFinite(m11)
    and isFinite(m12)
    and isFinite(m13)
    and isFinite(m14)
    and isFinite(m15)
    and isFinite(m16)
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
  local m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15, m16 =
    lovr.math.mat4(inverse):mul(pose):unpack(true)
  if
    not isFinite(m1)
    or math.abs(m1 - 1) > 1e-4
    or not isFinite(m2)
    or math.abs(m2 - 0) > 1e-4
    or not isFinite(m3)
    or math.abs(m3 - 0) > 1e-4
    or not isFinite(m4)
    or math.abs(m4 - 0) > 1e-4
    or not isFinite(m5)
    or math.abs(m5 - 0) > 1e-4
    or not isFinite(m6)
    or math.abs(m6 - 1) > 1e-4
    or not isFinite(m7)
    or math.abs(m7 - 0) > 1e-4
    or not isFinite(m8)
    or math.abs(m8 - 0) > 1e-4
    or not isFinite(m9)
    or math.abs(m9 - 0) > 1e-4
    or not isFinite(m10)
    or math.abs(m10 - 0) > 1e-4
    or not isFinite(m11)
    or math.abs(m11 - 1) > 1e-4
    or not isFinite(m12)
    or math.abs(m12 - 0) > 1e-4
    or not isFinite(m13)
    or math.abs(m13 - 0) > 1e-4
    or not isFinite(m14)
    or math.abs(m14 - 0) > 1e-4
    or not isFinite(m15)
    or math.abs(m15 - 0) > 1e-4
    or not isFinite(m16)
    or math.abs(m16 - 1) > 1e-4
  then
    return nil
  end
  return inverse
end

project = function(target: Quad, origin: vector, direction: vector, bounded: boolean): (number?, number?, number?)
  local width, height, pixelWidth, pixelHeight = target.width, target.height, target.pixelWidth, target.pixelHeight
  if
    not isFinite(width)
    or width <= 0
    or not isFinite(height)
    or height <= 0
    or not isFinite(pixelWidth)
    or pixelWidth <= 0
    or not isFinite(pixelHeight)
    or pixelHeight <= 0
  then
    return nil, nil, nil
  end

  local originX, originY, originZ = origin:unpack()
  local directionX, directionY, directionZ = direction:unpack()
  if
    not isFinite(originX)
    or not isFinite(originY)
    or not isFinite(originZ)
    or not isFinite(directionX)
    or not isFinite(directionY)
    or not isFinite(directionZ)
  then
    return nil, nil, nil
  end

  local inverse = inversePose(target.pose)
  if not inverse then
    return nil, nil, nil
  end
  local localOriginX, localOriginY, localOriginZ = inverse:mul(originX, originY, originZ, 1)
  local localDirectionX, localDirectionY, localDirectionZ = inverse:mul(directionX, directionY, directionZ, 0)
  if
    not isFinite(localOriginX)
    or not isFinite(localOriginY)
    or not isFinite(localOriginZ)
    or not isFinite(localDirectionX)
    or not isFinite(localDirectionY)
    or not isFinite(localDirectionZ)
  then
    return nil, nil, nil
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
