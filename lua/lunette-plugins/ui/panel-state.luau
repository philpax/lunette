-- Private panel and control records own geometry and gesture identity for one activation.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local surface = require '@lunette-contracts/surface'
local focus = require '@lunette-contracts/focus'
local globalTheme = require '@lunette-contracts/theme'
local control = require '@lunette-plugins/ui/control'
local owners = require '@lunette-plugins/ui/control-owners'
local draw = require './draw'

local state = {}

export type Control = {
  dead: boolean,
  id: string,
  owner: ui.Owner,
  identity: ui.OwnerIdentity,
  dispose: () -> boolean,
  kind: ui.Kind,
  label: string,
  bounds: ui.Bounds,
  enabled: boolean,
  z: number,
  order: number,
  exclusive: boolean,
  theme: ui.Theme,
  spec: ui.ThemeOverrides,
  lease: globalTheme.FontLease,
  measurements: draw.Cache,
  overrides: ui.ThemeOverrides?,
  draw: ui.DrawHook?,
  widget: control.Widget,
  target: focus.TargetHandle?,
  focused: boolean,
}
export type Capture = { control: Control, item: string? }
export type PendingInput = { control: Control, run: () -> () }
export type Panel = {
  dead: boolean,
  visible: boolean,
  cancelling: boolean,
  name: string,
  generation: ui.Generation,
  revision: number,
  owner: ui.Owner,
  pose: Mat4,
  width: number,
  height: number,
  logicalWidth: number,
  logicalHeight: number,
  grabbable: boolean,
  theme: ui.Theme,
  providerTheme: ui.ThemeOverrides,
  overrides: ui.ThemeOverrides?,
  spec: ui.ThemeOverrides,
  lease: globalTheme.FontLease,
  measurements: draw.Cache,
  themes: globalTheme.Service,
  themeRevision: number,
  radiusX: number,
  radiusY: number,
  refreshing: boolean,
  refresh: () -> (),
  providerDraw: ui.DrawHook?,
  draw: ui.DrawHook?,
  controls: { Control },
  owners: owners.Registry,
  nextOrder: number,
  surface: surface.Surface?,
  captures: { [surface.Pointer]: { [lunette.PointerButton]: Capture } },
  pendingInput: { PendingInput },
  hovered: { [surface.Pointer]: Control },
  pointerHover: { [surface.Pointer]: boolean },
  context: plugin.Context,
  focus: focus.Service,
}

return state
