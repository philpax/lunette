-- Registered font faces: each file is shaped natively and drawn with a LÖVR MSDF font made from the same bytes, so
-- measured and drawn glyphs come from one face.

local lunette = require '@lunette'

local fonts = {}

-- Glyphs rasterise at this em size in pixels; the MSDF field keeps them sharp when drawn larger.
local RASTER_SIZE = 48

export type Face = {
  family: string,
  weight: number,
  file: string,
  font: Font?,
}

export type Registry = {
  faces: { Face },
}

function fonts.new(): Registry
  return { faces = {} }
end

-- Reads the file, registers it for shaping, and adds the face. The returned function removes the face.
function fonts.add(registry: Registry, family: string, weight: number, file: string): () -> ()
  local data = lovr.filesystem.read(file)
  assert(type(data) == 'string', `ui: the font '{file}' could not be read`)
  -- The native fonts ignore a file they already hold, so a source reload adds no faces.
  lunette.loadLayoutFont(data)
  local face: Face = { family = family, weight = weight, file = file, font = nil }
  table.insert(registry.faces, face)
  return function(): ()
    local index = table.find(registry.faces, face)
    if index then
      table.remove(registry.faces, index)
    end
    if face.font then
      face.font:release()
      face.font = nil
    end
  end
end

-- The face of the family nearest the weight, or nil when the family has no face.
function fonts.match(registry: Registry, family: string, weight: number): Face?
  local best: Face? = nil
  for _, face in registry.faces do
    if face.family == family and (best == nil or math.abs(face.weight - weight) < math.abs(best.weight - weight)) then
      best = face
    end
  end
  return best
end

-- A LÖVR font whose unit is one em, created on first draw from a second read of the file.
function fonts.font(face: Face): Font
  local font = face.font
  if font == nil then
    local data = lovr.filesystem.read(face.file)
    assert(type(data) == 'string', `ui: the font '{face.file}' could not be read`)
    local created = lovr.graphics.newFont(lovr.data.newBlob(data, face.file), RASTER_SIZE)
    created:setPixelDensity(RASTER_SIZE)
    face.font = created
    return created
  end
  return font
end

function fonts.release(registry: Registry): ()
  for _, face in registry.faces do
    if face.font then
      face.font:release()
      face.font = nil
    end
  end
  table.clear(registry.faces)
end

return fonts
