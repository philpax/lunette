-- Measurement caches belong to one retained appearance and are cleared when its font changes.
local cache = {}
export type Cache = { font: Font?, entries: { unknown } }
function cache.new(): Cache
  return { font = nil, entries = {} }
end
function cache.clear(value: Cache): ()
  value.font, value.entries = nil, {}
end
-- The theme caches one face per font specification, so a changed font is always a new Font.
function cache.entries(value: Cache, font: Font): { unknown }
  if value.font ~= font then
    value.font, value.entries = font, {}
  end
  return value.entries
end
function cache.store(entries: { unknown }, value: unknown): ()
  if #entries == 32 then
    table.remove(entries, 1)
  end
  table.insert(entries, value)
end
return cache
