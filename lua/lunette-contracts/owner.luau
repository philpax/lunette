-- A caller lifetime used to acquire resources through a provider. Providers check it against their own
-- context before acquiring; queries need no owner. Every Context satisfies it.

local plugin = require '@lunette-plugin'

export type Owner = plugin.Owner

return {}
