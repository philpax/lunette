-- Ray intersection maps a flat quad hit to top-left pixel coordinates.

local quad = {}

export type Quad = {
  read pose: Mat4,
  read width: number,
  read height: number,
  read pixelWidth: number,
  read pixelHeight: number,
  read backFace: boolean?,
}

function quad.hit(target: Quad, origin: vector, direction: vector): (number?, number?, number?)
  if target.width <= 0 or target.height <= 0 or target.pixelWidth <= 0 or target.pixelHeight <= 0 then
    return nil, nil, nil
  end

  local originX, originY, originZ = origin:unpack()
  local directionX, directionY, directionZ = direction:unpack()

  -- Inversion writes in place, so copy the pose before transforming the ray.
  local inverse = lovr.math.mat4(target.pose):invert()
  local localOriginX, localOriginY, localOriginZ = inverse:mul(originX, originY, originZ, 1)
  local localDirectionX, localDirectionY, localDirectionZ = inverse:mul(directionX, directionY, directionZ, 0)

  if localDirectionZ == 0 then
    return nil, nil, nil
  end
  if localDirectionZ > 0 and not target.backFace then
    return nil, nil, nil
  end

  local distance = -localOriginZ / localDirectionZ
  if not (distance > 0) then
    return nil, nil, nil
  end

  local hitX = localOriginX + distance * localDirectionX
  local hitY = localOriginY + distance * localDirectionY
  local halfWidth, halfHeight = target.width / 2, target.height / 2
  if hitX < -halfWidth or hitX > halfWidth or hitY < -halfHeight or hitY > halfHeight then
    return nil, nil, nil
  end

  -- The quad's +y is up and a surface's +y is down.
  local pixelX = (hitX + halfWidth) / target.width * target.pixelWidth
  local pixelY = (halfHeight - hitY) / target.height * target.pixelHeight
  return pixelX, pixelY, distance
end

return quad
