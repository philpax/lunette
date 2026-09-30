-- Pure ray intersection for panel quads.
--
-- The calculation does not depend on the provider registry, a panel, or native
-- resources. It is kept separate so callers can use the same surface geometry
-- without acquiring a panel.

local raycast = {}

type Quad = {
  read pose: Mat4,
  read width: number,
  read height: number,
  read pixelWidth: number,
  read pixelHeight: number,
  read backFace: boolean?,
}

-- Returns the pixel coordinate and the distance along the ray, or nothing.
-- The pixel origin is the quad's top-left corner. A surface's pixels start
-- there, and `sink:pointer` uses the same origin.
function raycast.hit(quad: Quad, origin: vector, direction: vector): (number?, number?, number?)
  if quad.width <= 0 or quad.height <= 0 or quad.pixelWidth <= 0 or quad.pixelHeight <= 0 then
    return nil, nil, nil
  end

  local originX, originY, originZ = origin:unpack()
  local directionX, directionY, directionZ = direction:unpack()

  -- Inversion writes in place, so copy the pose before transforming the ray.
  local inverse = lovr.math.mat4(quad.pose):invert()
  local localOriginX, localOriginY, localOriginZ = inverse:mul(originX, originY, originZ, 1)
  local localDirectionX, localDirectionY, localDirectionZ = inverse:mul(directionX, directionY, directionZ, 0)

  if localDirectionZ == 0 then
    return nil, nil, nil
  end
  if localDirectionZ > 0 and not quad.backFace then
    return nil, nil, nil
  end

  local distance = -localOriginZ / localDirectionZ
  if not (distance > 0) then
    return nil, nil, nil
  end

  local hitX = localOriginX + distance * localDirectionX
  local hitY = localOriginY + distance * localDirectionY
  local halfWidth, halfHeight = quad.width / 2, quad.height / 2
  if hitX < -halfWidth or hitX > halfWidth or hitY < -halfHeight or hitY > halfHeight then
    return nil, nil, nil
  end

  -- The coordinates convert from metres to pixels. The vertical axis flips:
  -- the quad's +y is up and a surface's +y is down.
  local pixelX = (hitX + halfWidth) / quad.width * quad.pixelWidth
  local pixelY = (halfHeight - hitY) / quad.height * quad.pixelHeight
  return pixelX, pixelY, distance
end

return raycast
