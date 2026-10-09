-- Rejects table fields that a facade call or a plugin's own call does not name.

local fields = {}

type Raw = { [unknown]: unknown }

local listed: ({ string }) -> string

-- `level` offsets the error location from the caller: 1 names the caller, 2 its caller, and 0 omits a position.
function fields.rejectUnknownFields(prefix: string, value: unknown, allowed: { string }, level: number): ()
  local raised = if level == 0 then 0 else level + 1
  if type(value) ~= 'table' then
    error(string.format('%s: the argument is a table of fields, not a %s', prefix, type(value)), raised)
  end
  for key, _ in value :: Raw do
    if type(key) ~= 'string' or not table.find(allowed, key) then
      error(string.format('%s: unknown field %s; %s', prefix, tostring(key), listed(allowed)), raised)
    end
  end
end

-- Renders the allowed fields as prose with an Oxford comma.
listed = function(allowed: { string }): string
  local count = #allowed
  if count == 1 then
    return 'the field is ' .. allowed[1]
  elseif count == 2 then
    return 'the fields are ' .. allowed[1] .. ' and ' .. allowed[2]
  end
  return 'the fields are ' .. table.concat(allowed, ', ', 1, count - 1) .. ', and ' .. allowed[count]
end

return fields
