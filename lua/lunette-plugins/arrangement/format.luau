-- Reads and writes versioned arrangement files. File chunks run in an empty environment.

local vocabulary = require '@lunette-contracts/vocabulary'

local format = {}

export type Entry = {
  kind: 'window' | 'monitor',
  key: string,
  slot: number,
  pose: string,
  width: number?,
  height: number?,
  tags: { string },
}
export type File = { read entries: { Entry } }
export type Loaded =
  { read kind: 'arrangement', read file: File, read skipped: { string } }
  | { read kind: 'fromTheFuture', read found: number }
  | { read kind: 'broken', read message: string }

local quote: (string | number) -> string
local renderEntry: (Entry) -> string
local readEntry: (any) -> (Entry?, string?)

format.VERSION = 1

-- Malformed entries are refused and named in `skipped`; the rest load.
function format.read(text: string): Loaded
  local ok, chunk, failure = pcall(loadstring, text, '@arrangement')
  if not ok or not chunk then
    return { kind = 'broken', message = tostring(if ok then failure else chunk) }
  end
  -- File contents are untrusted even when this process wrote them.
  setfenv(chunk, {})

  local ran, held = pcall(chunk)
  if not ran then
    return { kind = 'broken', message = tostring(held) }
  end
  if type(held) ~= 'table' then
    return { kind = 'broken', message = 'the file holds a ' .. type(held) .. ', not an arrangement' }
  end

  local version = held.version
  if type(version) ~= 'number' or version ~= math.floor(version) or version < 1 then
    return { kind = 'broken', message = 'the file declares no version' }
  end
  if version > format.VERSION then
    return { kind = 'fromTheFuture', found = version }
  end
  if type(held.entries) ~= 'table' then
    return { kind = 'broken', message = 'the file holds no entry list' }
  end

  local entries: { Entry } = {}
  local skipped: { string } = {}
  for _, stored in ipairs(held.entries) do
    local entry, refused = readEntry(stored)
    if entry then
      entries[#entries + 1] = entry
    else
      skipped[#skipped + 1] = refused :: string
    end
  end
  return { kind = 'arrangement', file = { entries = entries }, skipped = skipped }
end

function format.render(file: File): string
  local lines = {
    '-- The arrangement lunette last saved.',
    'return {',
    '  version = ' .. format.VERSION .. ',',
    '  entries = {',
  }
  for _, entry in ipairs(file.entries) do
    lines[#lines + 1] = renderEntry(entry)
  end
  lines[#lines + 1] = '  },'
  lines[#lines + 1] = '}'
  return table.concat(lines, '\n') .. '\n'
end

quote = function(value: string | number): string
  if type(value) == 'string' then
    return string.format('%q', value)
  end
  -- Seventeen significant digits preserve the exact double across restarts.
  return string.format('%.17g', value)
end

-- Fixed field order keeps unchanged arrangements byte-for-byte stable. An absent size stays absent.
renderEntry = function(entry: Entry): string
  local fields = {
    'kind = ' .. quote(entry.kind),
    'key = ' .. quote(entry.key),
    'slot = ' .. quote(entry.slot),
    'pose = ' .. quote(entry.pose),
  }
  if entry.width then
    fields[#fields + 1] = 'width = ' .. quote(entry.width)
  end
  if entry.height then
    fields[#fields + 1] = 'height = ' .. quote(entry.height)
  end
  local tags: { string } = {}
  for index, name in ipairs(entry.tags) do
    tags[index] = quote(name)
  end
  fields[#fields + 1] = 'tags = { ' .. table.concat(tags, ', ') .. ' }'
  return '    { ' .. table.concat(fields, ', ') .. ' },'
end

local function size(value: unknown): boolean
  return value == nil or (type(value) == 'number' and value > 0 and value < math.huge)
end

-- The parameter is `any` because narrowing `unknown` reaches `table` and no further.
readEntry = function(stored: any): (Entry?, string?)
  if type(stored) ~= 'table' then
    return nil, 'an entry is a table, not a ' .. type(stored)
  end
  local kind = stored.kind
  if kind ~= 'window' and kind ~= 'monitor' then
    return nil, 'an entry is over a window or a monitor, not a ' .. tostring(kind)
  end
  local key = stored.key
  if type(key) ~= 'string' or key == '' then
    return nil, 'an entry is keyed by a name, and ' .. tostring(key) .. ' is not one'
  end
  local function refuse(reason: string): (Entry?, string?)
    return nil, "the entry for '" .. key .. "' " .. reason
  end
  local slot = stored.slot
  if type(slot) ~= 'number' or slot < 1 or slot ~= math.floor(slot) then
    return refuse 'has no slot'
  end
  if not vocabulary.decodePose(stored.pose) then
    return refuse 'carries no pose of sixteen numbers'
  end
  if not size(stored.width) or not size(stored.height) then
    return refuse 'has a size that is not a positive number'
  end
  if type(stored.tags) ~= 'table' then
    return refuse 'has no tag list'
  end
  local tags: { string } = {}
  for index, name in ipairs(stored.tags) do
    if type(name) ~= 'string' then
      return refuse('has a tag ' .. index .. ' that is not a name')
    end
    tags[index] = name
  end
  return {
    kind = kind,
    key = key,
    slot = slot,
    pose = stored.pose,
    width = stored.width,
    height = stored.height,
    tags = tags,
  }
end

return format
