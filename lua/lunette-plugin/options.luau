-- Option checks shared by the facade and its authors.

local options = {}

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

return options
