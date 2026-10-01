-- The layouts service contract.
--
-- A broker for named layouts. A layout is a function that poses a list of
-- panels; it holds no panels of its own and decides nothing about which
-- panels it is given. The caller chooses the panels, for example by resolving
-- a tag, and the layout by name, so a layout depends on no tags or rules and
-- a consumer that arranges panels depends on no particular layout.
--
-- A registration is owner-scoped: it lasts until the returned effect is
-- disposed or its owner unloads. A name names one registration, and
-- registering a name that is already registered raises. A built-in layout is
-- replaced by disabling the composition entry that registers it and
-- registering another under its name, never by overriding it in place.
--
-- apply poses the live panels of the list it is given with the named layout,
-- and raises for a name that is not registered. The layout's own error,
-- including one for options it does not take, is raised to the caller.
-- A continuous layout is one meant to be applied every frame, such as one that
-- follows the head; the broker does not apply it itself, and a consumer that
-- arranges with it applies it from its frame update.
--
-- onChanged listeners hear every registration that begins or ends, after the
-- change, so a consumer waiting for its layout arranges when it appears. A
-- listener runs under its own protected call, and its error is reported
-- through lunette.reportError.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local surface = require '@lunette-contracts/surface'

local layouts = {}

export type Owner = owner.Owner

-- What a layout poses: a surface it can move.
export type Panel = surface.Surface & {
  read setPose: (surface.Surface, Mat4) -> (),
}

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

-- Poses a panel. Luau reads `panel:setPose` on a Panel as an overload of the
-- surface's optional setPose and the Panel's own and cannot choose between
-- them, so a layout poses each panel through this.
function layouts.setPose(panel: Panel, pose: Mat4): ()
  local target: surface.Surface = panel
  local setPose = target.setPose
  if setPose then
    setPose(target, pose)
  end
end

layouts.capability = plugin.capability<<Service>> { name = 'lunette/layouts', schema = 1 }

return layouts
