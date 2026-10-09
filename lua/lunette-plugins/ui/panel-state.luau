-- Private panel and control records own geometry and gesture identity for one activation.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local globalTheme = require '@lunette-contracts/theme'
local owners = require '@lunette-plugins/ui/control-owners'
local draw = require './draw'
local rounded = require '@lunette-plugins/theme/rounded-geometry'
local drawing = require '@lunette-plugins/theme/drawing'
local vocabulary = require '@lunette-contracts/vocabulary'

export type Contour = { read bounds: ui.Bounds, read profile: rounded.Profile }
export type Shape = {
  read key: string,
  read bounds: ui.Bounds,
  read profile: rounded.Profile,
  read polygon: { rounded.Point },
  read clip: ui.Bounds,
}
export type Frame = { style: vocabulary.FrameStyle, joined: () -> boolean, dispose: () -> () }

local state = {}

-- A widget controller supplies input and visual state without owning panel resources.
export type Widget = {
  read methods: { read [string]: unknown },
  read receiver: focus.Receiver?,
  read keymapSeat: lunette.Seat?,
  read wantsKeyboard: boolean,
  read onFocus: ((boolean) -> ())?,
  read pointer: (vocabulary.PointerEvent, string?) -> (),
  read items: (ui.Bounds, ui.Theme) -> { read [number]: ui.ItemDescription },
  read visual: (ui.Visual) -> ui.Visual,
  read clearMeasurements: (() -> ())?,
}
-- A widget reaches its control's panel state only through its host.
export type Host = {
  read live: () -> boolean,
  read interactive: () -> boolean,
  read captured: (vocabulary.Pointer, lunette.PointerButton) -> boolean,
  read changed: () -> (),
  read cancel: (vocabulary.CancelReason) -> (),
  read focus: () -> boolean,
  read blur: () -> boolean,
  read bounds: () -> ui.Bounds,
  read clip: () -> ui.Bounds?,
  read textClip: (() -> ui.Bounds?)?,
  read theme: () -> ui.Theme,
  read callback: (string, () -> (), boolean?) -> boolean,
}

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
  measurements: draw.Cache,
  overrides: ui.ThemeOverrides?,
  draw: ui.DrawHook?,
  widget: Widget,
  target: focus.TargetHandle?,
  focused: boolean,
}
export type Capture = { control: Control, item: string? }
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
  measurements: draw.Cache,
  themes: globalTheme.Service,
  themeRevision: number,
  radiusX: number,
  radiusY: number,
  shape: Shape?,
  contour: Contour?,
  frame: Frame?,
  frameMeshes: drawing.Cache,
  refresh: () -> (),
  providerDraw: ui.DrawHook?,
  draw: ui.DrawHook?,
  controls: { Control },
  owners: owners.Registry,
  nextOrder: number,
  surface: vocabulary.Surface?,
  captures: { [vocabulary.Pointer]: { [lunette.PointerButton]: Capture } },
  hovered: { [vocabulary.Pointer]: Control },
  pointerHover: { [vocabulary.Pointer]: boolean },
  context: plugin.Context,
  focus: focus.Service,
}

return state
