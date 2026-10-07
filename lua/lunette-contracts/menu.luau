-- Menu actions belong to registering owners; rendering and action policy belong to consumers.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local inspection = require '@lunette-contracts/inspection'

local menu = {}

export type Owner = owner.Owner

export type Action = {
  read id: string,
  read label: string,
  read group: string?,
  read order: number?,
  read enabled: boolean?,
  read selected: boolean?,
  read run: () -> (),
}

-- Omitted state fields preserve their current values.
export type State = {
  read enabled: boolean?,
  read selected: boolean?,
}

-- Identity is by reference, not by the fields of this callback-free token.
export type Registration = {
  read kind: 'menu-registration',
}

export type Descriptor = {
  read id: string,
  read label: string,
  read group: string,
  read order: number,
  read enabled: boolean,
  read selected: boolean,
  read registration: Registration,
}

export type Result =
  { read kind: 'invoked' }
  | { read kind: 'unavailable' }
  | { read kind: 'failed', read message: string }

export type Service = {
  read register: (Service, Owner, Action) -> plugin.Effect,
  read update: (Service, Owner, plugin.Effect, State) -> boolean,
  read list: (Service) -> { read [number]: Descriptor },
  -- An expected registration prevents a stale row from invoking a replacement with the same id.
  read invoke: (Service, string, Registration?) -> Result,
  read inspect: (Service) -> inspection.Snapshot,
}

export type Capability = plugin.Capability<Service>

menu.capability = plugin.capability<<Service>> { name = 'lunette/menu', schema = 1 }

return menu
