-- Where a ray meets a quad, in the quad's own pixels.
--
-- The two halves of `mullion.panel` have nothing in common. This module is
-- arithmetic over a matrix and relies on `lovr.math` alone. The other half
-- deals with panel layers, their sources, and their draw calls.
--
-- A configuration can use the intersection on its own, for a quad that is
-- not a panel. `mullion.panel` re-exports `hit` as `panel.rayQuadHit`, the
-- name docs/dev/stdlib.md uses.

local raycast = {}

type Quad = {
  pose: Mat4,
  width: number,
  height: number,
  pixelWidth: number,
  pixelHeight: number,
  backFace: boolean?,
}

-- Returns the pixel coordinate and the distance along the ray, or nothing.
-- The pixel origin is the quad's top-left corner. A surface's pixels start
-- there, and `sink:pointer` uses the same origin.
--
-- LÖVR provides no ray-plane intersection. `Mat4` has no intersection
-- method, and LÖVR's raycasts operate in the physics world and need a
-- collider; a panel has no collider. The standard library provides the
-- intersection, as docs/dev/input.md records.
--
-- `quad` has `pose`, a `Mat4`; `width` and `height` in metres;
-- `pixelWidth` and `pixelHeight`; and `backFace`, which allows a hit from
-- behind and defaults to off. The direction need not be normalised. An
-- unnormalised direction gives a distance in units of the direction, and a
-- normalised direction gives a distance in metres.
function raycast.hit(quad: Quad, origin: vector, direction: vector): (number?, number?, number?)
  if quad.width <= 0 or quad.height <= 0 or quad.pixelWidth <= 0 or quad.pixelHeight <= 0 then
    return nil, nil, nil
  end

  local originX, originY, originZ = origin:unpack()
  local directionX, directionY, directionZ = direction:unpack()

  -- The transform moves the ray into the quad's own space, where the quad is
  -- the rectangle at z = 0. The pose is copied first, because `invert`
  -- writes in place; inverting the caller's pose would destroy it.
  local inverse = lovr.math.mat4(quad.pose):invert()
  local localOriginX, localOriginY, localOriginZ = inverse:mul(originX, originY, originZ, 1)
  -- With w = 0, the translation does not apply, because the vector is a
  -- direction.
  local localDirectionX, localDirectionY, localDirectionZ = inverse:mul(directionX, directionY, directionZ, 0)

  -- A ray parallel to the plane meets it nowhere. A ray travelling away from
  -- the viewer's side meets the back. A quad faces +z, as `Pass:plane`
  -- draws one. A ray approaching the front travels towards -z.
  if localDirectionZ == 0 then
    return nil, nil, nil
  end
  if localDirectionZ > 0 and not quad.backFace then
    return nil, nil, nil
  end

  local distance = -localOriginZ / localDirectionZ
  -- A negative distance places the hit behind the ray's origin. Zero is
  -- excluded too. A ray that starts exactly on the plane hits it at the
  -- ray's origin, and that point is not a hit.
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
