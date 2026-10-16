-- Registered font faces: each file is given to the native fonts, which shape text and whose glyphs the native
-- glyph atlas draws, so measured and drawn glyphs come from one face.

local lunette = require '@lunette'

local fonts = {}

export type Face = {
  family: string,
  weight: number,
  file: string,
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
  local face: Face = { family = family, weight = weight, file = file }
  table.insert(registry.faces, face)
  return function(): ()
    local index = table.find(registry.faces, face)
    if index then
      table.remove(registry.faces, index)
    end
  end
end

function fonts.release(registry: Registry): ()
  table.clear(registry.faces)
end

return fonts
