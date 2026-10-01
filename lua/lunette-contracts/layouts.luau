-- The layouts service contract: a broker for named layouts. A layout poses the panels its caller chooses
-- and holds none of its own, so a layout depends on no tags or rules. Registrations are owner-scoped, and a
-- name has one registration. See docs/dev/lua-api.md#layouts.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local surface = require '@lunette-contracts/surface'

local layouts = {}

export type Owner = owner.Owner

-- What a layout poses: a surface it can move, posed with `panel:setPose`.
export type Panel = surface.Movable

-- What register takes. apply receives the live panels in the order the caller
-- gave them, and the caller's options, which the layout validates.
export type Layout = {
  read name: string,
  read apply: ({ Panel }, unknown?) -> (),
  read continuous: boolean?,
}

-- What get answers about a registered layout.
export type Entry = {
  read name: string,
  read continuous: boolean,
}

-- What apply takes: the layout's name, the panels, and the layout's options.
export type Application = {
  read name: string,
  read panels: { Panel },
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
