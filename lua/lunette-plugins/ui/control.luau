-- Private widget controllers supply input and visual state without owning panel resources.
local lunette = require '@lunette'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local vocabulary = require '@lunette-contracts/vocabulary'

local control = {}

export type Widget = {
  read kind: ui.Kind,
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
  read withFont: ((Font) -> ()) -> (),
  read callback: (string, () -> (), boolean?) -> boolean,
}

return control
