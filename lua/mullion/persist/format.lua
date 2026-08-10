-- The arrangement file: its text, its versions, and the one type that may be
-- written.
--
-- Pure. Nothing here reads or writes a file; `mullion.persist` is the shell that
-- does, and it is the module a configuration requires. This half is separate
-- because the version matrix is the part worth reasoning about on its own, and
-- because a format that takes text in and hands data back needs no filesystem to
-- be exercised.
--
-- # The versions
--
-- The matrix is answered by construction, which is the shape
-- `crates/lunette-capture/src/tokens.rs` uses for the same problem:
--
-- - A new mullion reading an old file finds the fields it knows and nothing for
--   the ones that did not exist yet, which read as absent.
-- - An old mullion reading a new file gets a `fromTheFuture` load, and
--   `loaded:forSession()` answers nothing at all. That is the case worth
--   designing for: rewriting a file holding fields this version cannot
--   represent would drop them, corrupting the file rather than failing on it.
--   There is no arrangement to render and no file object to hand `save`, so the
--   rule cannot be lost to a later refactor that stops checking the kind.
-- - The version is bumped when a field is added, not when one is first depended
--   on. A default lets a new reader parse an old file; only the version stops an
--   old writer rewriting a new one.
--
-- # The text
--
-- A Lua chunk returning a table, loaded under an empty environment so that it
-- can build tables and reach nothing. `string.format`'s `%q` is the escaping,
-- which is the one part of writing a serialiser that has a tail worth not
-- writing again.
--
-- This module holds no state and starts nothing, so it registers no teardown
-- hook: there is nothing a reload could leave behind.

local format = {}

-- Declared here and defined below the public API, so the file reads
-- surface-first.
local fileMetatable, loadedMetatable, quote, renderEntry, readEntry

-- What this version of mullion writes.
format.CURRENT_VERSION = 1

-- The fields an entry is written with, in a fixed order, so that an arrangement
-- that has not changed renders identically and the file does not churn between
-- runs. `tags` is written last and separately, being the one that is a list.
format.ENTRY_FIELDS = { 'kind', 'key', 'slot', 'pose', 'width', 'height' }

-- An arrangement, from a list of entries.
--
-- The only constructor of something `render` accepts, and so the only thing
-- `mullion.persist.save` accepts. A caller cannot assemble one out of a plain
-- table, which is what makes the from-the-future rule structural rather than a
-- check somebody has to remember.
--
-- The list is copied, so a caller sorting or trimming its own array afterwards
-- does not quietly rewrite the arrangement that is about to be saved.
function format.newFile(entries)
  local held = {}
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
function format.isFile(value)
  return type(value) == 'table' and getmetatable(value) == fileMetatable
end

-- Whether `value` is a load `read`, `empty`, or `broken` produced.
--
-- A load and an arrangement are two different things and a caller holding the
-- wrong one is the mistake worth naming, so the two are told apart by their
-- metatables rather than by which fields happen to be present.
function format.isLoaded(value)
  return type(value) == 'table' and getmetatable(value) == loadedMetatable
end

-- An arrangement's entries, as a fresh array.
function format.entries(file)
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
function format.read(text)
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
    return setmetatable({
      kind = 'fromTheFuture',
      found = version,
      supported = format.CURRENT_VERSION,
      skipped = {},
    }, loadedMetatable)
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

  return setmetatable({
    kind = 'arrangement',
    version = version,
    file = format.newFile(entries),
    skipped = skipped,
  }, loadedMetatable)
end

-- A load carrying an empty arrangement, which is what a first run has.
function format.empty()
  return setmetatable({
    kind = 'arrangement',
    version = format.CURRENT_VERSION,
    file = format.newFile {},
    skipped = {},
  }, loadedMetatable)
end

-- A load of a file that could not be read at all.
function format.broken(message)
  return setmetatable({ kind = 'broken', message = message, skipped = {} }, loadedMetatable)
end

-- An arrangement as the file's text.
--
-- Always at `CURRENT_VERSION`: this is what this version writes, whatever
-- version the arrangement was read at.
function format.render(file)
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
    forSession = function(self)
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

-- A value as Lua source. Strings go through `%q`, which is the escaping that has
-- a tail worth not writing again.
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
function renderEntry(entry)
  local fields = {}
  for _, name in ipairs(format.ENTRY_FIELDS) do
    if entry[name] ~= nil then
      fields[#fields + 1] = name .. ' = ' .. quote(entry[name])
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
function readEntry(stored)
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
