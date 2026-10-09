-- Retained source-local contours are shared by native content drawing and picking.

local appearance = require '@lunette-plugins/panels/appearance'
local geometry = require '@lunette-plugins/theme/rounded-geometry'
local frame = require '@lunette-plugins/panels/frame'

local silhouette = {}

export type Cache = {
  width: number?,
  height: number?,
  radius: number?,
  joined: boolean?,
  bounds: geometry.Bounds?,
  profile: geometry.Profile?,
  polygon: { geometry.Point }?,
  key: string?,
}
export type Target = {
  read width: number,
  read height: number,
  read kind: 'window' | 'monitor',
  read frame: frame.Record?,
  contour: Cache?,
}

function silhouette.new(): Cache
  return {}
end

function silhouette.radius(target: Target, style: appearance.Style): number
  return if target.kind == 'window' then style.windowRadius else style.monitorRadius
end

function silhouette.get(
  target: Target,
  style: appearance.Style
): (geometry.Bounds, geometry.Profile, { geometry.Point }, boolean)
  local radius = silhouette.radius(target, style)
  local joined = frame.joined(target.frame)
  local cache = target.contour or silhouette.new()
  target.contour = cache
  if
    cache.width ~= target.width
    or cache.height ~= target.height
    or cache.radius ~= radius
    or cache.joined ~= joined
  then
    local bounds: geometry.Bounds = { x = 0, y = 0, width = target.width, height = target.height }
    local uniform = geometry.uniform(radius)
    local profile = geometry.profile(
      bounds,
      if joined
        then {
          topLeft = { x = 0, y = 0 },
          topRight = { x = 0, y = 0 },
          bottomRight = uniform.bottomRight,
          bottomLeft = uniform.bottomLeft,
        }
        else uniform
    )
    cache.width, cache.height, cache.radius, cache.joined = target.width, target.height, radius, joined
    cache.bounds, cache.profile, cache.polygon = bounds, profile, geometry.perimeter(bounds, profile)
    cache.key = geometry.key(bounds, profile)
  end
  return cache.bounds :: geometry.Bounds,
    cache.profile :: geometry.Profile,
    cache.polygon :: { geometry.Point },
    radius > 0
end

return silhouette
