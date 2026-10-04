-- Plugin options merge records recursively; lists and other values replace their defaults.

local options = {}

export type Spec<S> = {
  read name: string,
  read defaults: S,
  read config: unknown,
}

export type MergeSpec = {
  read base: { [string]: unknown }?,
  read over: { [string]: unknown }?,
}

type Raw = { [unknown]: unknown }

-- `level` offsets the error location from the caller: 1 names the caller, 2 its caller, and 0 omits a position.
function options.rejectUnknownFields(
  prefix: string,
  value: unknown,
  allowed: { [string]: boolean },
  fields: string,
  level: number
): ()
  local raised = if level == 0 then 0 else level + 1
  if type(value) ~= 'table' then
    error(string.format('%s: the argument is a table of fields, not a %s', prefix, type(value)), raised)
  end
  local listed = if next(allowed, (next(allowed))) == nil then 'the field is ' else 'the fields are '
  for key, _ in value :: Raw do
    if type(key) ~= 'string' or not allowed[key] then
      error(string.format('%s: unknown field %s; %s%s', prefix, tostring(key), listed, fields), raised)
    end
  end
end

local COUNTS = { 'one number', 'two numbers', 'three numbers', 'four numbers' }

-- List options replace defaults, so finite-number validation prevents invalid positions from reaching frame updates.
function options.checkNumbers(name: string, option: string, value: unknown, count: number): ()
  local what = COUNTS[count] or `{count} numbers`
  if type(value) ~= 'table' then
    error(string.format('plugin %s: option %s is %s, not a %s', name, option, what, type(value)), 0)
  end
  local list = value :: Raw
  for key, element in list do
    if type(key) ~= 'number' or key < 1 or key > count or key ~= math.floor(key) then
      local message = 'plugin %s: option %s is a list of %s, and %s is not one of its positions'
      error(message:format(name, option, what, tostring(key)), 0)
    end
    if type(element) ~= 'number' then
      error(string.format('plugin %s: option %s[%d] is a number, not a %s', name, option, key, type(element)), 0)
    end
    if element ~= element or element == math.huge or element == -math.huge then
      error(
        string.format('plugin %s: option %s[%d] is a finite number, not %s', name, option, key, tostring(element)),
        0
      )
    end
  end
  if #list ~= count then
    error(string.format('plugin %s: option %s is %s, not %d', name, option, what, #list), 0)
  end
end

function options.checkVector(name: string, option: string, value: unknown): ()
  if type(value) ~= 'vector' then
    error(string.format('plugin %s: option %s is a vector, not a %s', name, option, type(value)), 0)
  end
  local checked = value :: vector
  local components: { [string]: number } = { x = checked.x, y = checked.y, z = checked.z }
  for component, number in components do
    if number ~= number or number == math.huge or number == -math.huge then
      error(
        string.format('plugin %s: option %s.%s is a finite number, not %s', name, option, component, tostring(number)),
        0
      )
    end
  end
end

-- Empty tables replace defaults because they do not distinguish records from lists.
function options.isRecord(value: unknown): boolean
  if type(value) ~= 'table' or getmetatable(value :: any) ~= nil then
    return false
  end
  local raw = value :: Raw
  if rawlen(raw :: any) > 0 then
    return false
  end
  for key, _ in raw do
    if type(key) ~= 'string' then
      return false
    end
  end
  return next(raw) ~= nil
end

-- Native vectors and userdata are atomic values; metatable-backed tables retain their identity.
local function frozenCopy(value: unknown): unknown
  if type(value) ~= 'table' or getmetatable(value :: any) ~= nil then
    return value
  end
  local copy: Raw = {}
  for key, item in value :: Raw do
    copy[key] = frozenCopy(item)
  end
  return table.freeze(copy)
end

local function sortedKeys(raw: Raw): string
  local keys: { string } = {}
  for key, _ in raw do
    keys[#keys + 1] = tostring(key)
  end
  table.sort(keys)
  return table.concat(keys, ', ')
end

local function describe(path: string, key: unknown): string
  if path == '' then
    return tostring(key)
  end
  return path .. '.' .. tostring(key)
end

local function validated(name: string, path: string, defaults: Raw, given: Raw): Raw
  local result: Raw = table.clone(defaults)
  for key, value in given do
    local default = if type(key) == 'string' then defaults[key] else nil
    if default == nil then
      if next(defaults) == nil then
        error(string.format('plugin %s: unknown option %s; %s takes no options', name, describe(path, key), name), 0)
      end
      error(
        string.format(
          'plugin %s: unknown option %s; the options are %s',
          name,
          describe(path, key),
          sortedKeys(defaults)
        ),
        0
      )
    end
    if type(value) ~= type(default) then
      error(
        string.format('plugin %s: option %s is a %s, not a %s', name, describe(path, key), type(default), type(value)),
        0
      )
    end
    if options.isRecord(default) then
      result[key] = validated(name, describe(path, key), default :: Raw, value :: Raw)
    else
      result[key] = value
    end
  end
  return result
end

-- Configuration keys must exist in the defaults and values must match their default types. Nil configuration returns the defaults.
function options.resolve<S>(spec: Spec<S>): S
  local name, defaults, config = spec.name, spec.defaults, spec.config
  if config == nil then
    return frozenCopy(defaults) :: S
  end
  if type(config) ~= 'table' then
    error(string.format('plugin %s: the configuration is a table of options, not a %s', name, type(config)), 0)
  end
  local merged = validated(name, '', (defaults :: unknown) :: Raw, config :: Raw)
  return (frozenCopy(merged) :: unknown) :: S
end

local function merged(base: Raw, over: Raw): Raw
  local result: Raw = table.clone(base)
  for key, value in over do
    local previous = result[key]
    if options.isRecord(previous) and options.isRecord(value) then
      result[key] = merged(previous :: Raw, value :: Raw)
    else
      result[key] = value
    end
  end
  return result
end

-- Answers `over` merged over `base` by the configuration rule, without
-- validating either. Neither table is changed.
function options.merge(spec: MergeSpec): { [string]: unknown }
  local base, over = spec.base or {}, spec.over or {}
  return (merged(base :: Raw, over :: Raw) :: unknown) :: { [string]: unknown }
end

return options
