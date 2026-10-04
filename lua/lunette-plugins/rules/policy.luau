-- Extension functions are literal values unless their keys appear in the `evaluate` map.
local lunette = require '@lunette'
local rules = require '@lunette-contracts/rules'
local policy = {}

local named: { [string]: boolean } = {
  pose = true,
  width = true,
  height = true,
  title = true,
  priority = true,
  chrome = true,
  curve = true,
  hidden = true,
  adopt = true,
  tags = true,
}
local matchFields: { [string]: boolean } = {
  dead = true,
  id = true,
  title = true,
  appId = true,
  width = true,
  height = true,
  opaque = true,
  contentType = true,
  where = true,
}

function policy.matches(match: rules.Match?, window: lunette.Window): boolean
  if not match then
    return true
  end
  for key in pairs(match) do
    if not matchFields[key] then
      error('rules: unsupported match field ' .. key)
    end
  end
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
    if type(evaluator) ~= 'function' then
      error('rules: extension evaluator is not a function: ' .. key)
    end
    if named[key] or key == 'evaluate' then
      error('rules: extension evaluator uses reserved property ' .. key)
    end
    if applied[key] ~= nil then
      error('rules: property has both a literal and an evaluator: ' .. key)
    end
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
