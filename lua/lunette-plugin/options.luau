-- Field validation and configuration merging for plugin definitions. A record merges key by key; any other
-- value, lists included, replaces its default. The defaults are the schema.

local options = {}

-- The fields `plugin.options` accepts.
export type Spec<S> = {
  read name: string,
  read defaults: S,
  read config: unknown,
}

-- The fields `plugin.merge` accepts.
export type MergeSpec = {
  read base: { [string]: unknown }?,
  read over: { [string]: unknown }?,
}

type Raw = { [unknown]: unknown }

-- Raises an error naming the first key outside `allowed`, so a misspelt field is reported rather than
-- ignored. The error reads `<prefix>: unknown field <key>; the fields are <fields>`. `level` counts as
-- `error`'s does, but from the function that calls this one: 1 names that function, 2 its caller, and 0
-- gives no position.
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

-- Whether a value merges key by key rather than being replaced. An empty
-- table is not a record: nothing distinguishes an empty record from an empty
-- list, and replacing it loses nothing.
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

-- Copies plain tables recursively and freezes the copies. A table with a
-- metatable is a value of its own, such as a vector or matrix, and is kept.
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

-- Answers `config` merged over `defaults`, copied and frozen, raising for an option the defaults do not
-- name or a value of another type. A nil `config` answers the defaults.
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
