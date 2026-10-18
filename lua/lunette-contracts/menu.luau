-- Menu actions belong to registering owners; rendering and action policy belong to consumers.

local plugin = require '@lunette-plugin'
local inspection = require '@lunette-contracts/inspection'

local menu = {}

export type Owner = plugin.Owner

export type Action = {
  read id: string,
  read label: string,
  read group: string?,
  read enabled: boolean?,
  read selected: boolean?,
  read run: () -> (),
}

-- Omitted state fields preserve their current values.
export type State = {
  read enabled: boolean?,
  read selected: boolean?,
}

-- A registration the owner keeps to change its action's state. `update` returns false once the action is gone.
export type Registration = {
  read update: (Registration, State) -> boolean,
  read dispose: (Registration) -> (),
}

-- Identity is by reference, not by the fields of this callback-free token.
export type Token = {
  read kind: 'menu-token',
}

export type Descriptor = {
  read id: string,
  read label: string,
  read group: string,
  read enabled: boolean,
  read selected: boolean,
  read token: Token,
}

export type Result =
  { read kind: 'invoked' }
  | { read kind: 'unavailable' }
  | { read kind: 'failed', read message: string }

-- Runs after an action is registered, updated, or removed.
export type Listener = { read run: () -> () }

export type Service = {
  read register: (Service, Owner, Action) -> Registration,
  read list: (Service) -> { read [number]: Descriptor },
  -- An expected token prevents a stale row from invoking a replacement with the same id.
  read invoke: (Service, string, Token?) -> Result,
  read onChanged: (Service, Owner, Listener) -> plugin.Effect,
  read inspect: (Service) -> inspection.Snapshot,
}

export type Capability = plugin.Capability<Service>

menu.capability = plugin.capability<<Service>> { name = 'lunette/menu', version = 2 }

return menu
