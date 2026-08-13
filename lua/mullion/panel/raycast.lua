-- Where a ray meets a quad, in the quad's own pixels.
--
-- Split out of `mullion.panel` because the two halves have nothing in common:
-- this is arithmetic over a matrix and reaches for nothing but `lovr.math`,
-- while the other half is claims, layers, sources, and draw calls. It is also
-- the half a configuration is most likely to want on its own, for an object of
-- its own that is not a panel.
--
-- `mullion.panel` re-exports `hit` as `panel.rayQuadHit`, which is the name
-- docs/stdlib.md gives it.

local raycast = {}

type Quad = {
  pose: Mat4,
  width: number,
  height: number,
  pixelWidth: number,
  pixelHeight: number,
  backFace: boolean?,
}

-- Where a ray meets a quad, in the quad's own pixels.
--
-- Returns the pixel coordinate and the distance along the ray, or nothing. The
-- pixel origin is the quad's top-left corner, because that is where a surface's
-- pixels start and what `sink:pointer` takes.
--
-- LÖVR has no ray-plane intersection to call: `Mat4` has no intersection
-- method, and the only raycasts in it are physics-world ones needing a
-- collider, which a panel has not got. So the maths is here, which
-- docs/input.md:22 says is where it belongs.
--
-- `quad` carries `pose`, a `Mat4`; `width` and `height` in metres;
-- `pixelWidth` and `pixelHeight`; and `backFace`, which allows a hit from
-- behind and is off by default. The direction need not be normalised, but the
-- distance is then in units of it rather than in metres.
function raycast.hit(quad: Quad, origin: vector, direction: vector): (number?, number?, number?)
  if quad.width <= 0 or quad.height <= 0 or quad.pixelWidth <= 0 or quad.pixelHeight <= 0 then
    return nil, nil, nil
  end

  local originX, originY, originZ = origin:unpack()
  local directionX, directionY, directionZ = direction:unpack()

  -- Into the quad's own space, where the quad is the rectangle at z = 0. The
  -- pose is copied first: `invert` writes in place, and inverting the panel's
  -- own pose would destroy it.
  local inverse = lovr.math.mat4(quad.pose):invert()
  local localOriginX, localOriginY, localOriginZ = inverse:mul(originX, originY, originZ, 1)
  -- With w = 0, so the translation does not apply: this is a direction.
  local localDirectionX, localDirectionY, localDirectionZ = inverse:mul(directionX, directionY, directionZ, 0)

  -- A ray parallel to the plane meets it nowhere, and one travelling away from
  -- the viewer's side meets the back. A quad faces +z, as `Pass:plane` draws
  -- one, so a ray approaching the front travels towards -z.
  if localDirectionZ == 0 then
    return nil, nil, nil
  end
  if localDirectionZ > 0 and not quad.backFace then
    return nil, nil, nil
  end

  local distance = -localOriginZ / localDirectionZ
  -- Behind the ray's origin rather than in front of it. Zero is excluded too: a
  -- ray starting exactly on the plane is pointing along it as far as a panel is
  -- concerned.
  if not (distance > 0) then
    return nil, nil, nil
  end

  local hitX = localOriginX + distance * localDirectionX
  local hitY = localOriginY + distance * localDirectionY

  local halfWidth, halfHeight = quad.width / 2, quad.height / 2
  if hitX < -halfWidth or hitX > halfWidth or hitY < -halfHeight or hitY > halfHeight then
    return nil, nil, nil
  end

  -- Metres to pixels. The vertical axis flips: the quad's +y is up and a
  -- surface's +y is down.
  local pixelX = (hitX + halfWidth) / quad.width * quad.pixelWidth
  local pixelY = (halfHeight - hitY) / quad.height * quad.pixelHeight
  return pixelX, pixelY, distance
end

return raycast
