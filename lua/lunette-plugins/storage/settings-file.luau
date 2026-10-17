-- Reads and writes a caller's versioned settings file in LÖVR's save directory. Each known setting has a check, and
-- fields this version does not know are kept and written back, so a newer version's settings survive a session of an
-- older one. A file from a newer version is read for nothing and never overwritten.

local protected = require '@lunette-plugins/diagnostics/protected-call'

local settingsFile = {}

export type Check = (any) -> boolean

export type Spec = {
  -- The file's path in the save directory.
  read path: string,
  -- The context that problems are reported under, such as 'accessibility: settings'.
  read label: string,
  read version: number,
  -- A check for each known setting.
  read checks: { read [string]: Check },
  -- The value of every known setting when the file does not set it.
  read defaults: { read [string]: any },
}

export type File = {
  settings: { [string]: any },
  -- Fields of the settings table that this version does not know, kept as read.
  unknown: { [string]: any },
}

export type Loaded =
  { read kind: 'settings', read file: File, read skipped: { string } }
  | { read kind: 'fromTheFuture', read found: number }
  | { read kind: 'broken', read message: string }

-- An opened file: its settings, and whether saving may write it, which a file from a newer version forbids.
export type Opened = { file: File, writable: boolean }

-- Literal values that the file can hold: booleans, finite numbers, strings, and tables of them.
local function literal(value: any): boolean
  local kind = type(value)
  if kind == 'boolean' or kind == 'string' then
    return true
  elseif kind == 'number' then
    return value == value and math.abs(value) < math.huge
  elseif kind == 'table' then
    for key, item in value do
      if (type(key) ~= 'string' and type(key) ~= 'number') or not literal(item) then
        return false
      end
    end
    return true
  end
  return false
end

-- Whether a value is valid for a known setting; an unknown name is never valid here.
function settingsFile.valid(spec: Spec, name: string, value: any): boolean
  local check = spec.checks[name]
  return check ~= nil and check(value)
end

function settingsFile.read(spec: Spec, text: string): Loaded
  local ok, chunk, failure = pcall(loadstring, text, '@' .. spec.path)
  if not ok or not chunk then
    return { kind = 'broken', message = tostring(if ok then failure else chunk) }
  end
  -- File contents are untrusted even when this process wrote them.
  setfenv(chunk, {})
  local ran, held = pcall(chunk)
  if not ran then
    return { kind = 'broken', message = tostring(held) }
  end
  if type(held) ~= 'table' or type(held.version) ~= 'number' or type(held.settings) ~= 'table' then
    return { kind = 'broken', message = 'the file is not a versioned settings table' }
  end
  if held.version > spec.version then
    return { kind = 'fromTheFuture', found = held.version }
  end
  local settings = table.clone(spec.defaults) :: { [string]: any }
  local unknown: { [string]: any } = {}
  local skipped: { string } = {}
  for name, value in held.settings do
    if type(name) ~= 'string' then
      continue
    elseif spec.checks[name] then
      if spec.checks[name](value) then
        settings[name] = value
      else
        table.insert(skipped, name)
      end
    elseif literal(value) then
      unknown[name] = value
    else
      table.insert(skipped, name)
    end
  end
  table.sort(skipped)
  return { kind = 'settings', file = { settings = settings, unknown = unknown }, skipped = skipped }
end

local function render(value: any, indent: string): string
  local kind = type(value)
  if kind == 'string' then
    return string.format('%q', value)
  elseif kind == 'number' then
    return string.format('%.17g', value)
  elseif kind == 'boolean' then
    return tostring(value)
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
    local name = if type(key) == 'string' and string.match(key, '^[%a_][%w_]*$')
      then key
      else '[' .. render(key, '') .. ']'
    table.insert(lines, `{indent}  {name} = {render(value[key], indent .. '  ')},`)
  end
  return '{\n' .. table.concat(lines, '\n') .. '\n' .. indent .. '}'
end

function settingsFile.render(spec: Spec, file: File): string
  local settings: { [string]: any } = table.clone(file.unknown)
  for name, value in file.settings do
    settings[name] = value
  end
  return `return \{\n  version = {spec.version},\n  settings = {render(settings, '  ')},\n\}\n`
end

local function report(spec: Spec, message: string): ()
  protected.call(spec.label, function(): ()
    error(message, 0)
  end)
end

-- Reads the file, reporting invalid settings, a newer version, and a file that cannot be read, and answers the
-- defaults in place of anything it could not read.
function settingsFile.open(spec: Spec): Opened
  local opened: Opened = { file = { settings = table.clone(spec.defaults) :: any, unknown = {} }, writable = true }
  local text = lovr.filesystem.read(spec.path)
  if type(text) ~= 'string' then
    return opened
  end
  local loaded = settingsFile.read(spec, text)
  if loaded.kind == 'settings' then
    opened.file = loaded.file
    if #loaded.skipped > 0 then
      report(spec, `invalid settings were ignored: {table.concat(loaded.skipped, ', ')}`)
    end
  elseif loaded.kind == 'fromTheFuture' then
    opened.writable = false
    report(spec, `the settings file has version {loaded.found}, newer than this version reads; it is left unchanged`)
  else
    report(spec, `the settings file could not be read, so defaults apply until a setting changes: {loaded.message}`)
  end
  return opened
end

-- Writes the opened file's settings, unless it came from a newer version, and reports a failed write.
function settingsFile.save(spec: Spec, opened: Opened): ()
  if opened.writable and not lovr.filesystem.write(spec.path, settingsFile.render(spec, opened.file)) then
    report(spec, `the settings could not be saved to {spec.path}`)
  end
end

return settingsFile
