-- One current keyboard route is distinct from native per-seat focus. Disposal never restores an older route.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local inspection = require '@lunette-contracts/inspection'
local keys = require '@lunette-contracts/keys'

local focus = {}

export type Owner = plugin.Owner

-- Keys are evdev activations, not held-key streams. Committed UTF-8 text is a separate operation.
export type KeyEvent = {
  read code: number,
  read modifiers: { read [number]: string },
  read source: 'virtual' | 'physical',
  read isRepeat: boolean,
}

export type Receiver = {
  read key: (KeyEvent) -> boolean,
  read text: (string) -> boolean,
  read onFocus: ((Change) -> ())?,
  read onBlur: ((Change) -> ())?,
}

export type Target =
  { read kind: 'native', read seat: lunette.Seat?, read sink: lunette.Sink }
  | { read kind: 'local', read receiver: Receiver, read keymapSeat: lunette.Seat?, read wantsKeyboard: boolean }

export type TargetHandle = {
  read dead: boolean,
  read focus: (TargetHandle) -> boolean,
  read blur: (TargetHandle) -> boolean,
  read destroy: (TargetHandle) -> boolean,
}

-- Notifications carry live identity and revision directly. Inspection never executes receiver callbacks.
export type Change = {
  read target: TargetHandle?,
  read revision: number,
  read kind: 'none' | 'native' | 'local',
  read wantsKeyboard: boolean,
}

export type Listener = { read run: (Change) -> () }

export type Activation = {
  read code: number,
  read modifiers: { read [number]: string }?,
  read isRepeat: boolean?,
  read batch: number?,
  read physicalModifiers: keys.PhysicalModifiers?,
}

export type Result =
  { read kind: 'consumed' }
  | { read kind: 'unhandled' }
  | { read kind: 'failed', read message: string }
  | { read kind: 'refused', read message: string }

export type SourceOptions = {
  read mode: ('virtual' | 'physical')?,
}

export type Source = {
  read dead: boolean,
  read key: (Source, Activation) -> Result,
  read text: (Source, string, number?) -> Result,
  read keymapSeat: (Source) -> lunette.Seat?,
  read beginBatch: (Source, number) -> (),
  read reset: (Source) -> boolean,
  read destroy: (Source) -> boolean,
}

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read register: (Service, Owner, Target) -> TargetHandle,
  read focused: (Service) -> TargetHandle?,
  read revision: (Service) -> number,
  read onChanged: (Service, Owner, Listener) -> plugin.Effect,
  read newSource: (Service, Owner, SourceOptions?) -> Source,
}

-- Two native targets name the same route when their seats and sinks match. An omitted seat is the default seat.
function focus.sameNative(first: Target, second: Target): boolean
  if first.kind ~= 'native' or second.kind ~= 'native' or first.sink.domain ~= second.sink.domain then
    return false
  end
  local firstSeat = first.seat or lunette.defaultSeat()
  local secondSeat = second.seat or lunette.defaultSeat()
  if (firstSeat and firstSeat.id) ~= (secondSeat and secondSeat.id) then
    return false
  end
  if first.sink.domain == 'window' then
    return first.sink.id ~= nil and first.sink.id == second.sink.id
  end
  local firstMonitor, secondMonitor = first.sink.monitor, second.sink.monitor
  return firstMonitor ~= nil and secondMonitor ~= nil and firstMonitor.id == secondMonitor.id
end

export type Capability = plugin.Capability<Service>
focus.capability = plugin.capability<<Service>> { name = 'lunette/focus', schema = 2 }

return focus
