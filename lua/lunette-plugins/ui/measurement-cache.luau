-- Measurement caches belong to one retained appearance and never retain a font beyond that owner's lease.
local cache = {}
export type Cache = {
  font: Font?,
  measure: unknown,
  height: number?,
  density: number?,
  entries: { unknown },
}
function cache.new(): Cache
  return { font = nil, measure = nil, height = nil, density = nil, entries = {} }
end
function cache.clear(value: Cache): ()
  value.font, value.measure, value.height, value.density, value.entries = nil, nil, nil, nil, {}
end
function cache.entries(value: Cache?, font: Font): { unknown }?
  if not value then
    return nil
  end
  local height = font:getHeight()
  local density = if font.getPixelDensity then font:getPixelDensity() else nil
  if value.font ~= font or value.measure ~= font.getWidth or value.height ~= height or value.density ~= density then
    value.font, value.measure, value.height, value.density, value.entries = font, font.getWidth, height, density, {}
  end
  return value.entries
end
function cache.store(entries: { unknown }?, value: unknown): ()
  if entries then
    if #entries == 32 then
      table.remove(entries, 1)
    end
    table.insert(entries, value)
  end
end
return cache
