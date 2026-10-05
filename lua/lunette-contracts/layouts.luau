-- Layouts are owner-scoped named registrations. A layout receives caller-selected panels and owns no panels or tags.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local surface = require '@lunette-contracts/surface'

local layouts = {}

export type Owner = owner.Owner

export type Panel = surface.Movable

-- `apply` receives live panels in caller-supplied order. Each layout validates its own options.
export type Layout = {
  read name: string,
  read apply: ({ read [number]: Panel }, unknown?) -> (),
  read continuous: boolean?,
}

export type Entry = {
  read name: string,
  read continuous: boolean,
}

export type Application = {
  read name: string,
  read panels: { read [number]: Panel },
  read options: unknown?,
}

export type ChangedListener = {
  read run: () -> (),
}

export type Service = {
  read register: (Service, Owner, Layout) -> plugin.Effect,
  read apply: (Service, Application) -> (),
  read names: (Service) -> { string },
  read get: (Service, string) -> Entry?,
  read onChanged: (Service, Owner, ChangedListener) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

layouts.capability = plugin.capability<<Service>> { name = 'lunette/layouts', schema = 1 }

return layouts
