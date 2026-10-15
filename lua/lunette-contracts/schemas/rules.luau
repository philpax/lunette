-- Validates rule contract values and shares the closed sets used by rule evaluation.

local rules = require '@lunette-contracts/rules'
local checks = {}

type PropertyKind = 'pose' | 'number' | 'string' | 'boolean' | 'tags'
type MatchKind = 'number' | 'string' | 'boolean' | 'contentType' | 'function'
local propertyKinds: { read [string]: PropertyKind } = table.freeze({
  pose = 'pose',
  width = 'number',
  height = 'number',
  title = 'string',
  priority = 'number',
  chrome = 'boolean',
  curve = 'number',
  hidden = 'boolean',
  adopt = 'boolean',
  tags = 'tags',
} :: { [string]: PropertyKind })
local matchKinds: { read [string]: MatchKind } = table.freeze({
  dead = 'boolean',
  id = 'number',
  title = 'string',
  appId = 'string',
  width = 'number',
  height = 'number',
  opaque = 'boolean',
  contentType = 'contentType',
  where = 'function',
} :: { [string]: MatchKind })

checks.propertyKinds = propertyKinds
checks.matchKinds = matchKinds

local function checkedTable(value: unknown, label: string): { [unknown]: unknown }
  if type(value) ~= 'table' then
    error('rules: ' .. label .. ' is a table, not a ' .. type(value))
  end
  if getmetatable(value) ~= nil then
    error('rules: ' .. label .. ' is a plain table without a metatable')
  end
  return value :: { [unknown]: unknown }
end

local function isFinite(value: unknown): boolean
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function isMatrix(value: unknown): boolean
  if type(value) ~= 'userdata' then
    return false
  end
  local metatable: unknown = getmetatable(value)
  if type(metatable) ~= 'table' then
    return false
  end
  local fields = metatable :: { [string]: unknown }
  local kind = fields.type
  if type(kind) ~= 'function' then
    return false
  end
  local typeOf = kind :: (unknown) -> unknown
  return typeOf(value) == 'Mat4'
end

local function checkTags(value: unknown): ()
  local list = checkedTable(value, 'property tags')
  local count = #list
  for key in list do
    if type(key) ~= 'number' or key ~= math.floor(key) or key < 1 or key > count then
      error('rules: property tags is a list, and ' .. tostring(key) .. ' is not one of its positions')
    end
  end
  for index = 1, count do
    if type(list[index]) ~= 'string' then
      error('rules: property tags names a tag by a string at position ' .. index)
    end
  end
end

function checks.checkMatch(value: unknown): rules.Match
  local fields = checkedTable(value, 'a rule match')
  for key, field in fields do
    if type(key) ~= 'string' or not matchKinds[key] then
      error('rules: unsupported match field ' .. tostring(key))
    end
    local kind = matchKinds[key]
    local valid = type(field) == 'function'
      or (kind == 'contentType' and (field == 'none' or field == 'photo' or field == 'video' or field == 'game'))
      or (kind == 'number' and isFinite(field))
      or (kind ~= 'contentType' and kind ~= 'number' and type(field) == kind)
    if not valid then
      error('rules: the match field ' .. key .. ' is a ' .. kind .. ' or predicate, not a ' .. type(field))
    end
  end
  return value :: rules.Match
end

function checks.checkProperties(value: unknown): rules.Properties
  local fields = checkedTable(value, 'rule properties')
  for key, kind in propertyKinds do
    local field = fields[key]
    if field == nil or type(field) == 'function' then
      continue
    end
    if kind == 'tags' then
      checkTags(field)
    elseif
      not (
        (kind == 'pose' and (type(field) == 'string' or isMatrix(field)))
        or (kind == 'number' and isFinite(field))
        or (kind ~= 'pose' and kind ~= 'number' and type(field) == kind)
      )
    then
      error('rules: property ' .. key .. ' is a ' .. kind .. ' or function, not a ' .. type(field))
    end
  end
  for key in fields do
    if type(key) ~= 'string' then
      error('rules: a property key is a string, not a ' .. type(key))
    end
  end
  return value :: rules.Properties
end

function checks.checkRule(value: unknown, label: string): rules.Rule
  local fields = checkedTable(value, label)
  for key in fields do
    if key ~= 'match' and key ~= 'properties' then
      error('rules: ' .. label .. ' has an unknown field ' .. tostring(key) .. '; the fields are match and properties')
    end
  end
  if fields.match ~= nil then
    checks.checkMatch(fields.match)
  end
  if fields.properties ~= nil then
    checks.checkProperties(fields.properties)
  end
  return value :: rules.Rule
end

-- Rejects non-list keys, because list iteration would skip them.
function checks.checkRules(value: unknown): { read [number]: rules.Rule }
  local list = checkedTable(value, 'a rules list')
  local count = #list
  for key in list do
    if type(key) ~= 'number' or key ~= math.floor(key) or key < 1 or key > count then
      error('rules: a rules list is a list, and ' .. tostring(key) .. ' is not one of its positions')
    end
  end
  for index = 1, count do
    checks.checkRule(list[index], 'rule ' .. index)
  end
  return value :: { read [number]: rules.Rule }
end

return table.freeze(checks)
