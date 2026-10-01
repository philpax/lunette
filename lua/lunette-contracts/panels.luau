-- The panel service contract.
--
-- A panel registry belongs to one service instance. Creation is owner-scoped so
-- a provider can reject a caller from another plugin lifetime before it creates
-- a native layer claim or registers a panel. Only the owner that created a
-- panel destroys it.
--
-- onAdded and onRemoved are owner-scoped listeners. onAdded is called after a
-- panel enters the registry, from inside the call that created it. onRemoved
-- is called once a panel is dead, whatever ended it: its owner destroying it
-- or unloading, its source dying, or the provider unloading. A listener that
-- raises is reported through lunette.reportError and does not stop the others,
-- and it does not fail the operation that added or removed the panel.
--
-- A panel is hidden while the most recent live visibility override any owner
-- set says so, and shown when none is left. setHidden sets the owner's
-- override, one per owner: a later call moves it, making it the most recent,
-- and answers the same effect, and the override ends when the effect is disposed or the owner unloads. A
-- hidden panel is not drawn, gives up its layer claim, and is not offered to
-- pointers by the desktop; it stays in the registry and keeps its pose.
--
-- A panel with a positive curve is a piece of a cylinder of radius 1 / curve
-- whose centre is in front of the panel, as LÖVR curves a layer; its width is
-- measured along the arc. Monitor panels cannot hold a layer, because the
-- native claim API takes windows, so a curved monitor panel is always drawn
-- in the scene.
--
-- Panels do not draw borders or titles unless the provider's `chrome` option
-- or a panel's own says so. Decorations are a consumer's: the desktop's
-- `desktop/decorations` draws them from onAdded and onRemoved.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local surface = require '@lunette-contracts/surface'

local panels = {}

export type Owner = owner.Owner
export type Surface = surface.Surface
export type Source = lunette.Textured
export type Kind = 'window' | 'monitor'

export type Options = {
  read pose: Mat4?,
  read width: number?,
  read height: number?,
  read priority: number?,
  read title: string?,
  read chrome: boolean?,
  read curve: number?,
}

-- What setHidden sets: the owner's visibility override.
export type Visibility = {
  read hidden: boolean,
}

export type Style = {
  read borderThickness: number,
  read borderDepth: number,
  read borderColor: { number },
  read borderHighlightColor: { number },
  read titleHeight: number,
  read titleMargin: number,
  read titleColor: { number },
}

type PanelFields = {
  read pose: Mat4,
  read width: number,
  read height: number,
  read priority: number,
  read title: string?,
  read chrome: boolean,
  read curve: number,
  read hidden: boolean,
  read highlighted: boolean,
  read granted: boolean,
  read appliedWidth: number?,
  read appliedHeight: number?,
  read dead: boolean,
  read sink: (Surface) -> lunette.Sink?,
  read raycast: (Surface, vector, vector, boolean?) -> (number?, number?, number?),
  read setPose: (Surface, Mat4) -> (),
  read setSize: (Surface, number?, number?) -> (),
  read sourceSize: (Panel) -> (number?, number?),
  read update: (Panel) -> (),
  read draw: (Panel, Pass) -> (),
  read setHidden: (Panel, Owner, Visibility) -> plugin.Effect,
  read destroy: (Panel, Owner) -> boolean,
}

export type WindowPanel = PanelFields & { read kind: 'window', read source: lunette.Window }
export type MonitorPanel = PanelFields & { read kind: 'monitor', read source: lunette.Monitor }
export type Panel =
  PanelFields
  & ({ read kind: 'window', read source: lunette.Window } | { read kind: 'monitor', read source: lunette.Monitor })
export type PanelCallback = (Panel) -> ()

-- A removed listener hears every panel, or only panel when it is given.
export type RemovedListener = {
  read panel: Panel?,
  read run: PanelCallback,
}

export type Service = {
  read STYLE: Style,
  read fromWindow: (Service, Owner, lunette.Window, Options?) -> WindowPanel,
  read fromMonitor: (Service, Owner, lunette.Monitor, Options?) -> MonitorPanel,
  read all: (Service) -> { Panel },
  read forSource: (Service, Source) -> Panel?,
  read update: (Service) -> (),
  read draw: (Service, Pass) -> (),
  read onAdded: (Service, Owner, PanelCallback) -> plugin.Effect,
  read onRemoved: (Service, Owner, RemovedListener) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/panels', schema = 1 }

panels.capability = capability

return panels
