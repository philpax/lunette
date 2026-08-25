-- The pure arrangement format. `mullion.persist` owns filesystem access.
--
-- A newer reader accepts fields absent from older files. An older reader returns
-- `fromTheFuture` without an arrangement, so saving cannot discard unknown fields.
-- Bump the version when a field is added. A default alone does not protect a new
-- field when an old writer rewrites the file.
--
-- Files contain Lua tables loaded in an empty environment. Strings are escaped
-- with `%q`.

local format = {}

-- The fields of an entry that render as a scalar, as `ENTRY_FIELDS` names them
-- and `renderEntry` reads them. `tags` is not one: it is a list, and is written
-- separately. A closed set, so that both of those are checked against it rather
-- than against a bare string.
export type EntryField = 'kind' | 'key' | 'slot' | 'pose' | 'width' | 'height'

-- One entry: what an arrangement holds for a single window or monitor.
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

-- What this version of mullion writes.
format.CURRENT_VERSION = 1

-- The fields an entry is written with, in a fixed order, so that an arrangement
-- that has not changed renders identically and the file does not churn between
-- runs. `tags` is written last and separately, being the one that is a list.
format.ENTRY_FIELDS = { 'kind', 'key', 'slot', 'pose', 'width', 'height' } :: { EntryField }

-- An arrangement, from a list of entries.
--
-- The only constructor of values accepted by `render` and
-- `mullion.persist.save`, preserving the from-the-future distinction.
--
-- The list is copied, so a caller sorting or trimming its own array afterwards
-- does not quietly rewrite the arrangement that is about to be saved.
function format.newFile(entries: { Entry }): File
  local held: { Entry } = {}
  for index = 1, #(entries or {}) do
    local entry = entries[index]
    if type(entry) ~= 'table' then
      error('mullion.persist: entry ' .. index .. ' is a table, not a ' .. type(entry), 2)
    end
    held[index] = entry
  end
  return setmetatable({ entries = held }, fileMetatable)
end

-- Whether `value` is an arrangement this module made.
function format.isFile(value: unknown): boolean
  return type(value) == 'table' and getmetatable(value) == fileMetatable
end

-- Whether `value` is a load `read`, `empty`, or `broken` produced.
--
-- Loads and arrangements are distinguished by their metatables rather than by
-- whichever fields happen to be present.
function format.isLoaded(value: unknown): boolean
  return type(value) == 'table' and getmetatable(value) == loadedMetatable
end

-- An arrangement's entries, as a fresh array.
function format.entries(file: File): { Entry }
  if not format.isFile(file) then
    error('mullion.persist: an arrangement is one this module made, not a ' .. type(file), 2)
  end
  local copied = {}
  for index = 1, #file.entries do
    copied[index] = file.entries[index]
  end
  return copied
end

-- What the file's text says, as a load.
--
-- The load is one of three kinds, and `forSession` is what a caller asks for the
-- arrangement rather than reading the kind itself:
--
-- - `arrangement`, carrying one, and `skipped`, the entries it could not read.
-- - `fromTheFuture`, carrying `found` and `supported` and no arrangement.
-- - `broken`, carrying `message` and no arrangement.
--
-- Broken is a load rather than a raise. A save file is written by a previous
-- process and may have been truncated by a machine losing power mid-write, which
-- is an ordinary external condition rather than a defect in the caller.
--
-- An entry that is not the shape this version writes is skipped and named in
-- `skipped` rather than taken partially. A half-read entry would place a panel
-- somewhere nobody chose, which is harder to diagnose than one that did not come
-- back. Reporting is the shell's: this answers what happened and prints nothing.
function format.read(text: unknown): Loaded
  if type(text) ~= 'string' then
    return format.broken('the file is a ' .. type(text) .. ', not text')
  end

  -- LuaJIT returns `nil, message` for an unparseable chunk; Luau raises a
  -- syntax error instead. The file is broken either way, and the loader must
  -- report it, not propagate it.
  local ok, chunk = pcall(loadstring, text, '@arrangement')
  if not ok or not chunk then
    return format.broken(tostring(chunk or 'the file is not parseable'))
  end
  -- An empty environment, so the chunk can build tables and reach nothing. It is
  -- data this process wrote, and it is still read as though it were not.
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

-- A load carrying an empty arrangement, which is what a first run has.
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

-- A load of a file that could not be read at all.
function format.broken(message: string): BrokenLoad
  local broken: BrokenLoad = { kind = 'broken', message = message, skipped = {} }
  setmetatable(broken, loadedMetatable)
  return broken
end

-- An arrangement as the file's text.
--
-- Always at `CURRENT_VERSION`: this is what this version writes, whatever
-- version the arrangement was read at.
function format.render(file: File): string
  if not format.isFile(file) then
    error('mullion.persist: an arrangement is one this module made, not a ' .. type(file), 2)
  end

  local lines = {
    '-- The arrangement lunette last saved. Written by mullion.persist.',
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

-- The arrangement a load carries, or nothing.
--
-- Nothing for a load this version cannot represent, which is what stops it being
-- rewritten: there is no arrangement to render and nothing `save` accepts.
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

-- An arrangement. A table with this metatable and no other is what `render`
-- accepts, which is what makes `newFile` the only way to hold one.
fileMetatable = {}

-- A value as Lua source. Strings go through `%q`, because correct string
-- escaping has a long tail of edge cases that this module should not write
-- again.
function quote(value)
  if type(value) == 'string' then
    return string.format('%q', value)
  end
  if type(value) == 'number' then
    -- Seventeen digits, which brings a double back unchanged. A metre size that
    -- lost its last digit would shrink a panel a little at every restart, and
    -- the drift would be diagnosed as a layout defect rather than a formatting
    -- one.
    return string.format('%.17g', value)
  end
  error('mullion.persist: an entry holds strings and numbers, not a ' .. type(value))
end

-- One entry as a line of the file.
--
-- A field the entry does not carry is left out rather than written as nothing. A
-- reader takes an absent field as absent, which is how a file written before a
-- field existed reads to a version that has it.
function renderEntry(entry: Entry): string
  -- Keyed by `EntryField`, so a name here that the field set does not carry is a
  -- type error, and so is one in `ENTRY_FIELDS`. What the type cannot say is
  -- that every field is present; the spec in `persist/format_spec.lua` asserts
  -- that, so a field added to the set and not to this table fails there.
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

-- One entry out of a loaded table, or nothing and the reason it was refused.
-- `any` rather than `unknown`: this reads keys off a table that came from a
-- decoder, and narrowing `unknown` gets as far as `table` and no further.
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
