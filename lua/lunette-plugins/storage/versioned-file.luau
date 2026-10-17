-- Reads and writes a versioned file of literal values in LÖVR's save directory. The file is Lua that returns
-- `{ version = n, data = { ... } }`, run in an environment that holds only `vector`, because its contents are untrusted. Writes go through
-- `lunette.saveFile`, so a reader sees the previous file or the new one.

local lunette = require '@lunette'

local versionedFile = {}

export type Loaded =
  { read kind: 'missing' }
  | { read kind: 'data', read data: { [string]: any } }
  | { read kind: 'fromTheFuture', read found: number }
  | { read kind: 'broken', read message: string }

local function finite(value: number): boolean
  return value == value and math.abs(value) < math.huge
end

-- Whether a value can be written: a boolean, a finite number, a string, a vector of finite components, or a table of
-- them with string or number keys.
function versionedFile.literal(value: any): boolean
  local kind = type(value)
  if kind == 'boolean' or kind == 'string' then
    return true
  elseif kind == 'number' then
    return finite(value)
  elseif kind == 'vector' then
    return finite(value.x) and finite(value.y) and finite(value.z)
  elseif kind == 'table' then
    for key, item in value do
      if (type(key) ~= 'string' and type(key) ~= 'number') or not versionedFile.literal(item) then
        return false
      end
    end
    return true
  end
  return false
end

-- Parses a file's text against the newest version this reader knows.
function versionedFile.parse(text: string, name: string, version: number): Loaded
  local ok, chunk, failure = pcall(loadstring, text, '@' .. name)
  if not ok or not chunk then
    return { kind = 'broken', message = tostring(if ok then failure else chunk) }
  end
  setfenv(chunk, {
    vector = function(x: number, y: number, z: number): vector
      assert(type(x) == 'number' and type(y) == 'number' and type(z) == 'number', 'a vector has three numbers')
      return vector.create(x, y, z)
    end,
  })
  local ran, held = pcall(chunk)
  if not ran then
    return { kind = 'broken', message = tostring(held) }
  end
  if type(held) ~= 'table' or type(held.version) ~= 'number' or type(held.data) ~= 'table' then
    return { kind = 'broken', message = 'the file is not a versioned table of data' }
  end
  if held.version > version then
    return { kind = 'fromTheFuture', found = held.version }
  end
  if not versionedFile.literal(held.data) then
    return { kind = 'broken', message = 'the file holds a value other than a literal' }
  end
  return { kind = 'data', data = held.data }
end

function versionedFile.read(name: string, version: number): Loaded
  local text = lovr.filesystem.read(name)
  if type(text) ~= 'string' then
    return { kind = 'missing' }
  end
  return versionedFile.parse(text, name, version)
end

local function render(value: any, indent: string): string
  local kind = type(value)
  if kind == 'string' then
    return string.format('%q', value)
  elseif kind == 'number' then
    return string.format('%.17g', value)
  elseif kind == 'boolean' then
    return tostring(value)
  elseif kind == 'vector' then
    return `vector({render(value.x, '')}, {render(value.y, '')}, {render(value.z, '')})`
  end
  local keys: { any } = {}
  for key in value do
    table.insert(keys, key)
  end
  table.sort(keys, function(a: any, b: any): boolean
    return tostring(a) < tostring(b)
  end)
  local lines: { string } = {}
  for _, key in keys do
    local field = if type(key) == 'string' and string.match(key, '^[%a_][%w_]*$')
      then key
      else '[' .. render(key, '') .. ']'
    table.insert(lines, `{indent}  {field} = {render(value[key], indent .. '  ')},`)
  end
  if #lines == 0 then
    return '{}'
  end
  return '{\n' .. table.concat(lines, '\n') .. '\n' .. indent .. '}'
end

function versionedFile.render(data: { [string]: any }, version: number): string
  assert(versionedFile.literal(data), 'versioned file: the data holds a value other than a literal')
  return `return \{\n  version = {version},\n  data = {render(data, '  ')},\n\}\n`
end

-- Writes the data atomically, raising if the write fails.
function versionedFile.write(name: string, version: number, data: { [string]: any }): ()
  lunette.saveFile(lovr.filesystem.getSaveDirectory(), name, versionedFile.render(data, version))
end

return versionedFile
