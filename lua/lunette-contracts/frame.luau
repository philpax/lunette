-- Handlers run by phase, order, and registration. A key or text handler that returns true consumes the event.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local keys = require '@lunette-contracts/keys'

local frame = {}

export type Owner = plugin.Owner
export type UpdatePhase = 'input' | 'scene' | 'pointing' | 'overlay'
export type DrawPhase = UpdatePhase | 'feedback'
export type InputPhase = 'binding' | 'delivery'

-- IDs increase within one provider activation, not across replacements.
-- Each update opens a batch before update handlers; the first key or text callback opens one if none exists.
-- Key and text callbacks between update boundaries share the batch.
export type Batch = {
  read id: number,
  -- Binding key consumption or blockText blocks physical text until the next batch, without key/text correlation.
  read textBlocked: boolean,
}

export type BatchHandler = {
  read run: (Batch) -> (),
}

-- What lovr.keypressed reports, translated once for every handler. `isRepeat` is LÖVR's isrepeat, renamed because
-- `repeat` is reserved.
export type HostKeyEvent = {
  read batch: number,
  read key: KeyCode,
  read scancode: number,
  read isRepeat: boolean,
  -- The evdev code of the key, or nil for a LÖVR key with no evdev name.
  read code: number?,
  -- From the host snapshot when there is one, otherwise from the keys held now.
  read modifiers: { read [number]: lunette.ModifierName },
  -- Nil means the backend cannot report modifiers at the host event boundary.
  read physicalModifiers: keys.PhysicalModifiers?,
}

-- What lovr.textinput reports: the text, its first code point, and the modifiers held now.
export type HostTextEvent = {
  read batch: number,
  read text: string,
  read code: number,
  read modifiers: { read [number]: lunette.ModifierName },
}

export type UpdateHandler = {
  read phase: UpdatePhase,
  read order: number?,
  read run: (number) -> (),
}

export type DrawHandler = {
  read phase: DrawPhase,
  read order: number?,
  read run: (Pass) -> (),
}

export type KeyHandler = {
  read phase: InputPhase?,
  read order: number?,
  read run: (HostKeyEvent) -> boolean?,
}

export type TextHandler = {
  read phase: InputPhase?,
  read order: number?,
  read run: (HostTextEvent) -> boolean?,
}

-- What LÖVR's mouse callbacks report while its desktop window has input. Positions and movement are window pixels with
-- y downward, and `button` is LÖVR's number: 1 is primary, 2 secondary, and 3 middle. Wheel deltas are positive
-- rightward and upward.
export type HostMouseEvent =
  { read kind: 'move', read x: number, read y: number, read dx: number, read dy: number }
  | { read kind: 'press', read x: number, read y: number, read button: number }
  | { read kind: 'release', read x: number, read y: number, read button: number }
  | { read kind: 'wheel', read dx: number, read dy: number }

-- Mouse handlers run in registration order and cannot consume an event.
export type MouseHandler = {
  read run: (HostMouseEvent) -> (),
}

-- Simulate handlers run in registration order from `lovr.simulate`, which LÖVR calls each frame before the update
-- while the headset has no session, to drive the head and hands from the desktop window. While no simulate handler is
-- registered, LÖVR's own simulator runs.
export type SimulateHandler = {
  read run: (number) -> (),
}

export type QuitHandler = {
  read run: () -> (),
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  -- Returns false for a batch id that is not current. lua/lunette-contracts/docs/input.md#physical-input-batches states the protocol.
  read blockText: (Service, number) -> boolean,
  -- Registration reports the current batch immediately if one exists.
  read onBatch: (Service, Owner, BatchHandler) -> plugin.Effect,
  read onUpdate: (Service, Owner, UpdateHandler) -> plugin.Effect,
  read onDraw: (Service, Owner, DrawHandler) -> plugin.Effect,
  read onKey: (Service, Owner, KeyHandler) -> plugin.Effect,
  read onText: (Service, Owner, TextHandler) -> plugin.Effect,
  read onMouse: (Service, Owner, MouseHandler) -> plugin.Effect,
  read onSimulate: (Service, Owner, SimulateHandler) -> plugin.Effect,
  read onQuit: (Service, Owner, QuitHandler) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

-- Pointing updates resolve hits after the scene and before overlay reactions.
frame.UPDATE_PHASES = table.freeze { 'input', 'scene', 'pointing', 'overlay' } :: { UpdatePhase }

-- Feedback draws beams and landing indicators after all scene and overlay UI.
frame.DRAW_PHASES = table.freeze { 'input', 'scene', 'pointing', 'overlay', 'feedback' } :: { DrawPhase }

-- The key and text phases in the order they run.
frame.INPUT_PHASES = table.freeze { 'binding', 'delivery' } :: { InputPhase }

frame.capability = plugin.capability<<Service>> { name = 'lunette/frame', version = 3 }

return frame
