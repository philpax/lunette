local lunette = require '@lunette'
local ui = require '@lunette-contracts/ui'
local provider = require '@lunette-plugins/ui'

local definition = provider.definition
local requires = provider.requires
local variant = provider.define { theme = { fontSize = 18 } }

local function inspect(service: ui.Service): { read [number]: ui.Panel }
  local boundaries: { number } = lunette.textBoundaries ''
  assert(#boundaries == 1 and boundaries[1] == 1)
  return service:panels()
end

return { definition, requires, variant, inspect }
