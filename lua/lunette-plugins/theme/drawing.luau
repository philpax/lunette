-- Caches clipped rounded faces and outline rings within the drawing owner's lifetime.

local geometry = require './rounded-geometry'

local drawing = {}

export type Entry = { read key: string, read mesh: Mesh? }
export type Cache = { entries: { Entry }, limit: number }

local LIMIT = 96
local submit: (Pass, Cache, string, () -> ({ { number } }, { number })) -> ()

function drawing.newCache(limit: number?): Cache
  local capacity = limit or LIMIT
  assert(capacity > 0 and capacity < math.huge and capacity % 1 == 0, 'theme drawing: invalid cache capacity')
  return { entries = {}, limit = capacity }
end

function drawing.clear(cache: Cache): ()
  local entries = table.clone(cache.entries)
  table.clear(cache.entries)
  local failures: { string } = {}
  for _, entry in entries do
    if entry.mesh then
      local completed, failure = pcall(entry.mesh.release, entry.mesh)
      if not completed then
        failures[#failures + 1] = tostring(failure)
      end
    end
  end
  if #failures > 0 then
    error('theme drawing cleanup: ' .. table.concat(failures, '; '), 0)
  end
end

function drawing.face(
  pass: Pass,
  cache: Cache,
  bounds: geometry.Bounds,
  profile: geometry.Profile,
  clip: geometry.Bounds?
): ()
  local key = 'face ' .. geometry.key(bounds, profile, clip)
  submit(pass, cache, key, function(): ({ { number } }, { number })
    local polygon = geometry.perimeter(bounds, profile)
    return geometry.triangles(if clip then geometry.clip(polygon, clip) else polygon)
  end)
end

function drawing.border(
  pass: Pass,
  cache: Cache,
  bounds: geometry.Bounds,
  profile: geometry.Profile,
  thickness: number,
  clip: geometry.Bounds?
): ()
  local key = 'border ' .. geometry.key(bounds, profile, clip, thickness)
  submit(pass, cache, key, function(): ({ { number } }, { number })
    return geometry.ring(bounds, profile, thickness, clip)
  end)
end

function drawing.insideBorder(
  pass: Pass,
  cache: Cache,
  bounds: geometry.Bounds,
  profile: geometry.Profile,
  thickness: number,
  clip: geometry.Bounds?
): ()
  local key = 'inside border ' .. geometry.key(bounds, profile, clip, thickness)
  submit(pass, cache, key, function(): ({ { number } }, { number })
    return geometry.insideRing(bounds, profile, thickness, clip)
  end)
end

submit = function(pass: Pass, cache: Cache, key: string, make: () -> ({ { number } }, { number })): ()
  for index, entry in cache.entries do
    if entry.key == key then
      table.remove(cache.entries, index)
      cache.entries[#cache.entries + 1] = entry
      if entry.mesh then
        pass:draw(entry.mesh)
      end
      return
    end
  end
  local vertices, indices = make()
  local mesh: Mesh? = nil
  if #indices > 0 then
    local acquired = lovr.graphics.newMesh(#vertices)
    local completed, failure = pcall(function(): ()
      acquired:setVertices(vertices)
      acquired:setIndices(indices)
    end)
    if not completed then
      local released, releaseFailure = pcall(acquired.release, acquired)
      error(tostring(failure) .. (if released then '' else '; ' .. tostring(releaseFailure)), 0)
    end
    mesh = acquired
  end
  if #cache.entries >= cache.limit then
    local oldest = assert(table.remove(cache.entries, 1), 'theme drawing: missing oldest cache entry')
    if oldest.mesh then
      local completed, failure = pcall(oldest.mesh.release, oldest.mesh)
      if not completed then
        if mesh then
          local released, releaseFailure = pcall(mesh.release, mesh)
          error(tostring(failure) .. (if released then '' else '; ' .. tostring(releaseFailure)), 0)
        end
        error(failure, 0)
      end
    end
  end
  cache.entries[#cache.entries + 1] = { key = key, mesh = mesh }
  if mesh then
    pass:draw(mesh)
  end
end

return drawing
