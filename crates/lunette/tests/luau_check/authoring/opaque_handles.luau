local lunette = require '@lunette'

local runtime = lunette.plugin.runtime()
local token = lunette.plugin.contract('fixture/opaque', 1)
runtime:use({}, {}) -- reject: PluginDefinition.
runtime:use(token, {}) -- reject: PluginDefinition.
return token
