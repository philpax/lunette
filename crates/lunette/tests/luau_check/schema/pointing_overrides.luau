local plugin = require '@lunette-plugin'
local laser = require '@lunette-contracts/laser'
local interaction = require '@lunette-contracts/interaction'
local pointing = require '@lunette-plugins/desktop/pointing/config'

local function attach(service: laser.Service, pointers: interaction.Service, owner: plugin.Context): ()
  local colorOnly: pointing.Settings = pointing.schema.parse { laser = { style = { color = { 1, 0, 0, 1 } } } }
  local reachOnly: pointing.Settings = pointing.schema.parse { laser = { tuning = { reach = 3 } } }
  service:attach(owner, colorOnly.laser)
  service:attach(owner, reachOnly.laser)
  pointers:newPointer(owner, { tuning = reachOnly.laser.tuning })
end

return attach
