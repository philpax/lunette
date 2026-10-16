-- The plugin manager's outlets, which other plugins contribute interface to through the UI host.

local schema = require '@lunette-plugin/schema'
local uiHost = require '@lunette-contracts/ui-host'

local pluginManager = {}

-- The selected entry's settings page in the Configure tab. `entry` is the entry's id and `name` its plugin
-- definition name, which a contribution compares with its own plugin's to show a page only for it. The outlet is
-- attributed, and it never holds the manager's lifecycle controls.
pluginManager.settings = uiHost.outlet {
  name = 'lunette/manager/settings',
  version = { major = 1, minor = 0 },
  props = schema.object { entry = schema.string(), name = schema.string() },
  attributed = true,
}

export type SettingsProps = schema.Output<typeof(pluginManager.settings.props)>

return pluginManager
