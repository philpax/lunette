-- The panel registry owns panel lifetimes and owner-scoped visibility overrides.

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

export type Visibility = {
  read hidden: boolean,
}

export type Style = {
  read borderThickness: number,
  read borderDepth: number,
  read borderColor: { read [number]: number },
  read borderHighlightColor: { read [number]: number },
  read titleHeight: number,
  read titleMargin: number,
  read titleColor: { read [number]: number },
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
  -- Requests window closure or dismisses and removes a monitor panel; the caller must be live.
  read close: (Panel, Owner) -> boolean,
  read destroy: (Panel, Owner) -> boolean,
}

export type WindowPanel = PanelFields & { read kind: 'window', read source: lunette.Window }
export type MonitorPanel = PanelFields & { read kind: 'monitor', read source: lunette.Monitor }
export type Panel =
  PanelFields
  & ({ read kind: 'window', read source: lunette.Window } | { read kind: 'monitor', read source: lunette.Monitor })
export type PanelCallback = (Panel) -> ()

-- A removed listener can filter notifications by panel.
export type RemovedListener = {
  read panel: Panel?,
  read run: PanelCallback,
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
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

local capability = plugin.capability<<Service>> { name = 'lunette/panels', schema = 2 }

panels.capability = capability

return panels
