-- The panel service contract.
--
-- A panel registry belongs to one service instance. Creation is owner-scoped so
-- a provider can reject a caller from another plugin lifetime before it creates
-- a native layer claim or registers a panel.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local surface = require '@lunette-contracts/surface'
local vocabulary = require '@lunette-contracts/vocabulary'

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
  read destroy: (Panel) -> boolean,
}

export type WindowPanel = PanelFields & { read kind: 'window', read source: lunette.Window }
export type MonitorPanel = PanelFields & { read kind: 'monitor', read source: lunette.Monitor }
export type Panel =
  PanelFields
  & ({ read kind: 'window', read source: lunette.Window } | { read kind: 'monitor', read source: lunette.Monitor })
export type DroppedCallback = (Panel, vocabulary.Pointer) -> ()

export type Quad = {
  read pose: Mat4,
  read width: number,
  read height: number,
  read pixelWidth: number,
  read pixelHeight: number,
  read backFace: boolean?,
}

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
  read onDropped: (Service, Owner, Panel?, DroppedCallback) -> plugin.Effect,
  read emitDropped: (Service, Owner, Panel, vocabulary.Pointer) -> (),
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability('lunette/panels', 1, function(value: Service): Service
  return value
end)

panels.capability = capability

return panels
