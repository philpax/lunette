-- Reads and writes the versioned accessibility settings file. Fields this version does not know are kept and written
-- back, so a newer version's settings survive a session of an older one.

local accessibility = require '@lunette-contracts/accessibility'

local format = {}

format.VERSION = 1

export type File = {
  settings: accessibility.Settings,
  -- Fields of the settings table that this version does not know, kept as read.
  unknown: { [string]: any },
}

export type Loaded =
  { read kind: 'settings', read file: File, read skipped: { string } }
  | { read kind: 'fromTheFuture', read found: number }
  | { read kind: 'broken', read message: string }

type Check = (any) -> boolean

local CHECKS: { [string]: Check } = {
  reducedMotion = function(value: any): boolean
    return type(value) == 'boolean'
  end,
  textScale = function(value: any): boolean
    return type(value) == 'number' and value >= 0.5 and value <= 2
  end,
  highContrast = function(value: any): boolean
    return type(value) == 'boolean'
  end,
  timing = function(value: any): boolean
    return type(value) == 'number' and value >= 0.5 and value <= 5
  end,
  haptics = function(value: any): boolean
    return type(value) == 'boolean'
  end,
  sounds = function(value: any): boolean
    return type(value) == 'boolean'
  end,
  handedness = function(value: any): boolean
    return value == 'left' or value == 'right'
  end,
}

-- Whether a value is valid for a known setting; an unknown name is never valid here.
function format.valid(name: string, value: any): boolean
  local check = CHECKS[name]
  return check ~= nil and check(value)
end

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

function format.read(text: string): Loaded
  local ok, chunk, failure = pcall(loadstring, text, '@accessibility')
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
  if held.version > format.VERSION then
    return { kind = 'fromTheFuture', found = held.version }
  end
  local settings = table.clone(accessibility.DEFAULTS) :: any
  local unknown: { [string]: any } = {}
  local skipped: { string } = {}
  for name, value in held.settings do
    if type(name) ~= 'string' then
      continue
    elseif CHECKS[name] then
      if CHECKS[name](value) then
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

function format.render(file: File): string
  local settings: { [string]: any } = table.clone(file.unknown)
  for name, value in file.settings :: any do
    settings[name] = value
  end
  return `return \{\n  version = {format.VERSION},\n  settings = {render(settings, '  ')},\n\}\n`
end

return format
