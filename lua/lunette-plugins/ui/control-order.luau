-- Controls paint from low to high z, with later registration above earlier controls on ties.
local records = require '@lunette-plugins/ui/panel-state'

local order = {}

function order.ordered(controls: { read [number]: records.Control }): { records.Control }
  local result: { records.Control } = {}
  for _, control in controls do
    result[#result + 1] = control
  end
  table.sort(result, function(first: records.Control, second: records.Control): boolean
    return first.z < second.z or (first.z == second.z and first.order < second.order)
  end)
  return result
end

return order
