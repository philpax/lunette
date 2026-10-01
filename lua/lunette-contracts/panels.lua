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

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local surface = require '@lunette-contracts/surface'
local vocabulary = require '@lunette-contracts/vocabulary'
local quad = require '@lunette-contracts/quad'

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
  read drawChrome: (Panel, Pass) -> (),
  read destroy: (Panel, Owner) -> boolean,
}

export type WindowPanel = PanelFields & { read kind: 'window', read source: lunette.Window }
export type MonitorPanel = PanelFields & { read kind: 'monitor', read source: lunette.Monitor }
export type Panel =
  PanelFields
  & ({ read kind: 'window', read source: lunette.Window } | { read kind: 'monitor', read source: lunette.Monitor })
export type DroppedCallback = (Panel, vocabulary.Pointer) -> ()
export type PanelCallback = (Panel) -> ()

-- A dropped or removed listener hears every panel, or only panel when it is
-- given.
export type DroppedListener = {
  read panel: Panel?,
  read run: DroppedCallback,
}

export type RemovedListener = {
  read panel: Panel?,
  read run: PanelCallback,
}

export type Quad = quad.Quad

export type Service = {
  read STYLE: Style,
  read DEFAULT_PRIORITY: number,
  read DEFAULT_HEIGHT: number,
  read DEFAULT_ASPECT: number,
  read OPAQUE_FRAGMENT: string,
  read rayQuadHit: (Service, Quad, vector, vector) -> (number?, number?, number?),
  read fromWindow: (Service, Owner, lunette.Window, Options?) -> WindowPanel,
  read fromMonitor: (Service, Owner, lunette.Monitor, Options?) -> MonitorPanel,
  read all: (Service) -> { Panel },
  read forSource: (Service, Source) -> Panel?,
  read update: (Service) -> (),
  read draw: (Service, Pass) -> (),
  read opaqueShader: (Service, Owner) -> Shader?,
  read onDropped: (Service, Owner, DroppedListener) -> plugin.Effect,
  read emitDropped: (Service, Owner, Panel, vocabulary.Pointer) -> (),
  read onAdded: (Service, Owner, PanelCallback) -> plugin.Effect,
  read onRemoved: (Service, Owner, RemovedListener) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/panels', schema = 1 }

panels.capability = capability

return panels
