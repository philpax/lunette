local workspaces = require '@lunette-plugins/desktop/workspaces/config'

local config: workspaces.Config = { workspaces = { { name = 'main', key = '1' } } }
local entries = config.workspaces
if entries then
  entries[1].name = 'renamed'
  entries[1].key = '2'
  entries[2] = { name = 'second', key = '3' }
end

return config
