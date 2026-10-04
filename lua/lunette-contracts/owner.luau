-- Providers validate an owner against their context before acquiring resources. Queries do not require an owner.

local plugin = require '@lunette-plugin'

export type Owner = plugin.Owner

return {}
