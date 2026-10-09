-- Extension functions are literal values unless their keys appear in the `evaluate` map.
local lunette = require '@lunette'
local rules = require '@lunette-contracts/rules'
local policy = {}

local named: { [string]: string } = {
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
}
local matchFields: { [string]: string } = {
  dead = 'boolean',
  id = 'number',
  title = 'string',
  appId = 'string',
  width = 'number',
  height = 'number',
  opaque = 'boolean',
  contentType = 'contentType',
  where = 'function',
}

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

function policy.checkMatch(value: unknown): rules.Match
  local fields = checkedTable(value, 'a rule match')
  for key, field in fields do
    if type(key) ~= 'string' or not matchFields[key] then
      error('rules: unsupported match field ' .. tostring(key))
    end
    local kind = matchFields[key]
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

function policy.checkProperties(value: unknown): rules.Properties
  local fields = checkedTable(value, 'rule properties')
  for key, kind in named do
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
      error('rules: property ' .. key .. ' is a ' .. kind .. ' or evaluator, not a ' .. type(field))
    end
  end
  for key in fields do
    if type(key) ~= 'string' then
      error('rules: a property key is a string, not a ' .. type(key))
    end
  end
  if fields.evaluate ~= nil then
    local evaluators = checkedTable(fields.evaluate, 'evaluate')
    for key, evaluator in evaluators do
      if type(key) ~= 'string' then
        error('rules: an evaluator key is a string, not a ' .. type(key))
      end
      if type(evaluator) ~= 'function' then
        error('rules: extension evaluator is not a function: ' .. key)
      end
      if named[key] or key == 'evaluate' then
        error('rules: extension evaluator uses reserved property ' .. key)
      end
      if fields[key] ~= nil then
        error('rules: property has both a literal and an evaluator: ' .. key)
      end
    end
  end
  return value :: rules.Properties
end

function policy.checkRule(value: unknown, label: string): rules.Rule
  local fields = checkedTable(value, label)
  for key in fields do
    if key ~= 'match' and key ~= 'properties' then
      error('rules: ' .. label .. ' has an unknown field ' .. tostring(key) .. '; the fields are match and properties')
    end
  end
  if fields.match ~= nil then
    policy.checkMatch(fields.match)
  end
  if fields.properties ~= nil then
    policy.checkProperties(fields.properties)
  end
  return value :: rules.Rule
end

-- Rejects non-list keys, because `ipairs` would skip them.
function policy.checkRules(value: unknown): { read [number]: rules.Rule }
  local list = checkedTable(value, 'a rules list')
  local count = #list
  for key in list do
    if type(key) ~= 'number' or key ~= math.floor(key) or key < 1 or key > count then
      error('rules: a rules list is a list, and ' .. tostring(key) .. ' is not one of its positions')
    end
  end
  for index = 1, count do
    policy.checkRule(list[index], 'rule ' .. index)
  end
  return value :: { read [number]: rules.Rule }
end

function policy.matches(match: rules.Match?, window: lunette.Window): boolean
  if not match then
    return true
  end
  policy.checkMatch(match)
  local dead, id, title, appId = match.dead, match.id, match.title, match.appId
  local width, height, opaque, contentType = match.width, match.height, match.opaque, match.contentType
  if dead ~= nil and not (if type(dead) == 'function' then dead(window.dead, window) else dead == window.dead) then
    return false
  end
  if id ~= nil and not (if type(id) == 'function' then id(window.id, window) else id == window.id) then
    return false
  end
  if
    title ~= nil and not (if type(title) == 'function' then title(window.title, window) else title == window.title)
  then
    return false
  end
  if
    appId ~= nil and not (if type(appId) == 'function' then appId(window.appId, window) else appId == window.appId)
  then
    return false
  end
  if
    width ~= nil and not (if type(width) == 'function' then width(window.width, window) else width == window.width)
  then
    return false
  end
  if
    height ~= nil
    and not (if type(height) == 'function' then height(window.height, window) else height == window.height)
  then
    return false
  end
  if
    opaque ~= nil
    and not (if type(opaque) == 'function' then opaque(window.opaque, window) else opaque == window.opaque)
  then
    return false
  end
  if
    contentType ~= nil
    and not (
      if type(contentType) == 'function'
        then contentType(window.contentType, window)
        else contentType == window.contentType
    )
  then
    return false
  end
  local where = match.where
  if where ~= nil then
    if type(where) ~= 'function' then
      error('rules: the match field where is a function of the window, not a ' .. type(where))
    end
    if not where(window) then
      return false
    end
  end
  return true
end

function policy.layer(collected: rules.Properties, applied: rules.Properties): rules.Properties
  policy.checkProperties(applied)
  local evaluators: { [string]: (lunette.Window, string) -> unknown } = {}
  local previous: { read [string]: (lunette.Window, string) -> unknown } = collected.evaluate or {}
  for key, evaluator in previous do
    evaluators[key] = evaluator
  end
  for key, value in pairs(applied) do
    if key ~= 'evaluate' then
      collected[key] = value
      evaluators[key] = nil
    end
  end
  local incoming: { read [string]: (lunette.Window, string) -> unknown } = applied.evaluate or {}
  for key, evaluator in incoming do
    collected[key] = nil
    evaluators[key] = evaluator
  end
  collected['evaluate'] = evaluators
  return collected
end

function policy.evaluate(properties: rules.Properties, window: lunette.Window): rules.Resolved
  local pose, width, height, title = properties.pose, properties.width, properties.height, properties.title
  local priority, chrome, curve, tags = properties.priority, properties.chrome, properties.curve, properties.tags
  local hidden, adopt = properties.hidden, properties.adopt
  local result: rules.Resolved = {
    pose = if type(pose) == 'function' then pose(window, 'pose') else pose,
    width = if type(width) == 'function' then width(window, 'width') else width,
    height = if type(height) == 'function' then height(window, 'height') else height,
    title = if type(title) == 'function' then title(window, 'title') else title,
    priority = if type(priority) == 'function' then priority(window, 'priority') else priority,
    chrome = if type(chrome) == 'function' then chrome(window, 'chrome') else chrome,
    curve = if type(curve) == 'function' then curve(window, 'curve') else curve,
    hidden = if type(hidden) == 'function' then hidden(window, 'hidden') else hidden,
    adopt = if type(adopt) == 'function' then adopt(window, 'adopt') else adopt,
    tags = if type(tags) == 'function' then tags(window, 'tags') else tags,
  }
  for key, value in pairs(properties) do
    if not named[key] and key ~= 'evaluate' then
      result[key] = value
    end
  end
  local evaluators: { read [string]: (lunette.Window, string) -> unknown } = properties.evaluate or {}
  for key, evaluator in evaluators do
    if named[key] or key == 'evaluate' then
      error('rules: extension evaluator uses reserved property ' .. key)
    end
    result[key] = evaluator(window, key)
  end
  return result
end

return policy
