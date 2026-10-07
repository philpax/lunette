local workspaces = require '@lunette-plugins/desktop/workspaces/config'

local settings: workspaces.Settings = workspaces.schema.parse { workspaces = { { name = 'main' } } }
settings.workspaces[1].name = 'renamed'
settings.workspaces[1] = { name = 'second' }

return settings
