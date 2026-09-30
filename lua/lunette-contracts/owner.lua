-- A caller lifetime used to acquire resources through a provider.
--
-- Providers check this owner with their own context before acquisition, then
-- register acquisition and cleanup through owner:effect. Queries need no owner.
-- The facade's Context.effect must accept this structural Owner as its receiver,
-- not Context<S>, so contexts with different service records satisfy it.

local plugin = require '@lunette-plugin'

export type Owner = {
  read services: (never) -> unknown,
  read effect: (Owner, () -> () -> ()) -> plugin.Effect,
}

return {}
