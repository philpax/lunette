-- Caches clipped rounded faces and outline rings within the drawing owner's lifetime.

local geometry = require './rounded-geometry'

local drawing = {}

export type Entry = { read key: string, read mesh: Mesh? }
export type Cache = { entries: { Entry } }

local LIMIT = 96
local submit: (Pass, Cache, string, () -> ({ { number } }, { number })) -> ()

function drawing.newCache(): Cache
  return { entries = {} }
end

function drawing.clear(cache: Cache): ()
  for _, entry in cache.entries do
    if entry.mesh then
      entry.mesh:release()
    end
  end
  table.clear(cache.entries)
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
    local created = lovr.graphics.newMesh(#vertices)
    created:setVertices(vertices)
    created:setIndices(indices)
    mesh = created
  end
  if #cache.entries >= LIMIT then
    local oldest = table.remove(cache.entries, 1)
    if oldest and oldest.mesh then
      oldest.mesh:release()
    end
  end
  cache.entries[#cache.entries + 1] = { key = key, mesh = mesh }
  if mesh then
    pass:draw(mesh)
  end
end

return drawing
