-- Evaluates validated rules; functions under extension property keys remain literal values.

local lunette = require '@lunette'
local rules = require '@lunette-contracts/rules'
local checks = require '@lunette-contracts/schemas/rules'
local policy = {}

-- The match was checked when its rule was registered.
function policy.matches(match: rules.Match?, window: lunette.Window): boolean
  if not match then
    return true
  end
  local fields = (match :: unknown) :: { [string]: unknown }
  local source = (window :: unknown) :: { [string]: unknown }
  for key in checks.matchKinds do
    local wanted = fields[key]
    if wanted == nil or key == 'where' then
      continue
    end
    local actual = source[key]
    if type(wanted) == 'function' then
      if not (wanted :: (unknown, lunette.Window) -> boolean)(actual, window) then
        return false
      end
    elseif wanted ~= actual then
      return false
    end
  end
  local where = match.where
  return where == nil or where(window)
end

-- The applied properties were checked when their rule was registered or their source answered.
function policy.layer(collected: rules.Properties, applied: rules.Properties): rules.Properties
  for key, value in pairs(applied) do
    collected[key] = value
  end
  return collected
end

function policy.evaluate(properties: rules.Properties, window: lunette.Window): rules.Resolved
  local given = (properties :: unknown) :: { [string]: unknown }
  local result: { [string]: unknown } = {}
  for key, value in given do
    result[key] = if checks.propertyKinds[key] and type(value) == 'function'
      then (value :: (lunette.Window, string) -> unknown)(window, key)
      else value
  end
  return (result :: unknown) :: rules.Resolved
end

return policy
