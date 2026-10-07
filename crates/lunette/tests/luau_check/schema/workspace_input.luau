local workspaces = require '@lunette-plugins/desktop/workspaces/config'

local config: workspaces.Config = { workspaces = { { name = 'main' } } }
local entries = config.workspaces
if entries then
  entries[1].name = 'renamed'
  entries[2] = { name = 'second' }
end

return config
