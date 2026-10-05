local workspaces = require '@lunette-plugins/desktop/workspaces/config'

local settings: workspaces.Settings = workspaces.schema.parse { workspaces = { { name = 'main', key = '1' } } }
settings.workspaces[1].name = 'renamed'
settings.workspaces[1].key = '2'
settings.workspaces[1] = { name = 'second', key = '3' }

return settings
