-- Reads and writes versioned arrangement files. Future versions load without a writable arrangement, preventing old readers from dropping fields they cannot represent. Missing fields remain absent. File chunks run in an empty environment.

local format = {}

-- Scalar entry fields form a closed set; tags are serialized separately as a list.
export type EntryField = 'kind' | 'key' | 'slot' | 'pose' | 'width' | 'height'

export type Entry = {
  kind: 'window' | 'monitor',
  key: string,
  slot: number,
  pose: string,
  width: number?,
  height: number?,
  tags: { string },
}
export type File = {
  entries: { Entry },
}
type ArrangementLoad = {
  kind: 'arrangement',
  version: number,
  file: File,
  skipped: { string },
  forSession: ((Loaded) -> File?)?,
}
type FutureLoad = {
  kind: 'fromTheFuture',
  found: number,
  supported: number,
  skipped: { string },
  forSession: ((Loaded) -> File?)?,
}
type BrokenLoad = {
  kind: 'broken',
  message: string,
  skipped: { string },
  forSession: ((Loaded) -> File?)?,
}
export type Loaded = ArrangementLoad | FutureLoad | BrokenLoad

local fileMetatable, loadedMetatable, quote
local renderEntry: (Entry) -> string
local readEntry: (any) -> (Entry?, string?)

format.CURRENT_VERSION = 1

-- Fixed field order keeps unchanged arrangements byte-for-byte stable.
format.ENTRY_FIELDS = { 'kind', 'key', 'slot', 'pose', 'width', 'height' } :: { EntryField }

-- Copies the entry array so callers cannot mutate a pending save through that array.
function format.newFile(entries: { Entry }): File
  local held: { Entry } = {}
  for index = 1, #(entries or {}) do
    local entry = entries[index]
    if type(entry) ~= 'table' then
      error('desktop.persist: entry ' .. index .. ' is a table, not a ' .. type(entry), 2)
    end
    held[index] = entry
  end
  return setmetatable({ entries = held }, fileMetatable)
end

function format.isFile(value: unknown): boolean
  return type(value) == 'table' and getmetatable(value) == fileMetatable
end

-- Loads and arrangements use distinct metatables, independent of their fields.
function format.isLoaded(value: unknown): boolean
  return type(value) == 'table' and getmetatable(value) == loadedMetatable
end

function format.entries(file: File): { Entry }
  if not format.isFile(file) then
    error('desktop.persist: an arrangement is one this module made, not a ' .. type(file), 2)
  end
  local copied = {}
  for index = 1, #file.entries do
    copied[index] = file.entries[index]
  end
  return copied
end

-- Returns a broken load for parse or I/O damage, skips malformed entries, and reports them in `skipped`. Unsupported versions return no writable arrangement.
function format.read(text: unknown): Loaded
  if type(text) ~= 'string' then
    return format.broken('the file is a ' .. type(text) .. ', not text')
  end

  -- LuaJIT returns a parse error; Luau raises one. Both become broken loads.
  local ok, chunk = pcall(loadstring, text, '@arrangement')
  if not ok or not chunk then
    return format.broken(tostring(chunk or 'the file is not parseable'))
  end
  -- File contents are untrusted even when this process wrote them.
  setfenv(chunk, {})

  local ran, held = pcall(chunk)
  if not ran then
    return format.broken(tostring(held))
  end
  if type(held) ~= 'table' then
    return format.broken('the file holds a ' .. type(held) .. ', not an arrangement')
  end

  local version = held.version
  if type(version) ~= 'number' or version ~= math.floor(version) or version < 1 then
    return format.broken 'the file declares no version'
  end
  if version > format.CURRENT_VERSION then
    local future: FutureLoad = {
      kind = 'fromTheFuture',
      found = version,
      supported = format.CURRENT_VERSION,
      skipped = {},
    }
    setmetatable(future, loadedMetatable)
    return future
  end

  local entries, skipped = {}, {}
  for _, stored in ipairs(held.entries or {}) do
    local entry, refused = readEntry(stored)
    if entry then
      entries[#entries + 1] = entry
    else
      skipped[#skipped + 1] = refused
    end
  end

  local arrangement: ArrangementLoad = {
    kind = 'arrangement',
    version = version,
    file = format.newFile(entries),
    skipped = skipped,
  }
  setmetatable(arrangement, loadedMetatable)
  return arrangement
end

function format.empty(): ArrangementLoad
  local arrangement: ArrangementLoad = {
    kind = 'arrangement',
    version = format.CURRENT_VERSION,
    file = format.newFile {},
    skipped = {},
  }
  setmetatable(arrangement, loadedMetatable)
  return arrangement
end

function format.arrangement(
  fields: { read file: File, read version: number, read skipped: { string }? }
): ArrangementLoad
  if not format.isFile(fields.file) then
    error('desktop.persist: an arrangement load carries an arrangement newFile made', 2)
  end
  local arrangement: ArrangementLoad = {
    kind = 'arrangement',
    version = fields.version,
    file = fields.file,
    skipped = table.clone(fields.skipped or {}),
  }
  setmetatable(arrangement, loadedMetatable)
  return arrangement
end

-- Marks a newer file as unsupported so an older writer cannot drop its fields.
function format.fromTheFuture(fields: { read found: number, read supported: number }): FutureLoad
  local future: FutureLoad = {
    kind = 'fromTheFuture',
    found = fields.found,
    supported = fields.supported,
    skipped = {},
  }
  setmetatable(future, loadedMetatable)
  return future
end

function format.broken(message: string): BrokenLoad
  local broken: BrokenLoad = { kind = 'broken', message = message, skipped = {} }
  setmetatable(broken, loadedMetatable)
  return broken
end

-- Renders every arrangement with the current format version.
function format.render(file: File): string
  if not format.isFile(file) then
    error('desktop.persist: an arrangement is one this module made, not a ' .. type(file), 2)
  end

  local lines = {
    '-- The arrangement lunette last saved. Written by desktop.persist.',
    'return {',
    '  version = ' .. format.CURRENT_VERSION .. ',',
    '  entries = {',
  }
  for _, entry in ipairs(file.entries) do
    lines[#lines + 1] = renderEntry(entry)
  end
  lines[#lines + 1] = '  },'
  lines[#lines + 1] = '}'
  return table.concat(lines, '\n') .. '\n'
end

-- Future and broken loads expose no arrangement that a caller can write back.
loadedMetatable = {
  __index = {
    forSession = function(self: Loaded): File?
      if self.kind ~= 'arrangement' then
        return nil
      end
      return self.file
    end,
  },
}

fileMetatable = {}

function quote(value)
  if type(value) == 'string' then
    return string.format('%q', value)
  end
  if type(value) == 'number' then
    -- Seventeen significant digits preserve the exact double across restarts.
    return string.format('%.17g', value)
  end
  error('desktop.persist: an entry holds strings and numbers, not a ' .. type(value))
end

-- Missing optional fields remain absent in the rendered file.
function renderEntry(entry: Entry): string
  -- The format specification test checks that every named field is serialized.
  local values: { [EntryField]: string | number | nil } = {
    kind = entry.kind,
    key = entry.key,
    slot = entry.slot,
    pose = entry.pose,
    width = entry.width,
    height = entry.height,
  }

  local fields = {}
  for _, name in ipairs(format.ENTRY_FIELDS) do
    local value = values[name]
    if value ~= nil then
      fields[#fields + 1] = name .. ' = ' .. quote(value)
    end
  end

  local tags = {}
  for index, name in ipairs(entry.tags or {}) do
    tags[index] = quote(name)
  end
  fields[#fields + 1] = 'tags = { ' .. table.concat(tags, ', ') .. ' }'

  return '    { ' .. table.concat(fields, ', ') .. ' },'
end

-- One entry out of a loaded table, or nothing and the reason it is refused.
-- The parameter is `any`, not `unknown`: this reads keys off a table that came
-- from a decoder, and narrowing `unknown` gets as far as `table` and no further.
function readEntry(stored: any): (Entry?, string?)
  if type(stored) ~= 'table' then
    return nil, 'an entry is a table, not a ' .. type(stored)
  end

  local kind = stored.kind
  if kind ~= 'window' and kind ~= 'monitor' then
    return nil, 'an entry is over a window or a monitor, not a ' .. tostring(kind)
  end
  if type(stored.key) ~= 'string' or stored.key == '' then
    return nil, 'an entry is keyed by a name, and ' .. tostring(stored.key) .. ' is not one'
  end
  if type(stored.pose) ~= 'string' then
    return nil, "the entry for '" .. stored.key .. "' carries no pose"
  end

  local tags = {}
  for _, name in ipairs(stored.tags or {}) do
    if type(name) == 'string' then
      tags[#tags + 1] = name
    end
  end

  return {
    kind = kind,
    key = stored.key,
    slot = type(stored.slot) == 'number' and stored.slot or 1,
    pose = stored.pose,
    width = type(stored.width) == 'number' and stored.width or nil,
    height = type(stored.height) == 'number' and stored.height or nil,
    tags = tags,
  }
end

return format
