-- A caller lifetime used to acquire resources through a provider.
--
-- Providers check this owner with their own context before acquisition, then
-- register acquisition and cleanup through owner:effect, or do both with
-- Context:acquire. Queries need no owner. The type is the facade's Owner, which
-- every Context satisfies whatever services it requires.

local plugin = require '@lunette-plugin'

export type Owner = plugin.Owner

return {}
