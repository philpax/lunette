-- Handlers run by phase, order, and registration. A key or text handler that returns true consumes the event.

local plugin = require '@lunette-plugin'
local keys = require '@lunette-contracts/keys'

local frame = {}

export type Owner = plugin.Owner
export type UpdatePhase = 'input' | 'scene' | 'pointing' | 'overlay'
export type DrawPhase = UpdatePhase | 'feedback'
-- Retained for callers that share a phase between update and draw.
export type Phase = UpdatePhase
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

-- What lovr.keypressed reports. `isRepeat` is LÖVR's isrepeat, renamed because `repeat` is reserved.
export type KeyEvent = {
  read batch: number,
  read key: KeyCode,
  read scancode: number,
  read isRepeat: boolean,
  -- Nil means the backend cannot report modifiers at the host event boundary.
  read modifiers: keys.PhysicalModifiers?,
}

-- What lovr.textinput reports: the text and its first code point.
export type TextEvent = {
  read batch: number,
  read text: string,
  read code: number,
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
  read run: (KeyEvent) -> boolean?,
}

export type TextHandler = {
  read phase: InputPhase?,
  read order: number?,
  read run: (TextEvent) -> boolean?,
}

export type QuitHandler = {
  read run: () -> (),
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  -- Blocks physical text in the current batch without advancing its id or mutating an earlier frozen Batch.
  -- State changes before observers run. Repeated requests succeed without another notification.
  -- Returns false without effects for a non-current id or an absent batch; a cached method also rejects an ended activation.
  read blockText: (Service, number) -> boolean,
  -- Observers run in registration order at boundaries before update, binding, and delivery handlers.
  -- A binding key handler returning true replaces the frozen Batch with textBlocked = true and the same id.
  -- Observers receive that metadata change before another physical callback; the next batch opens unblocked.
  -- Registration immediately reports the same frozen current Batch if one exists, without opening a batch.
  -- Every notification reports callback errors and continues to later observers unless a newer Batch supersedes it.
  read onBatch: (Service, Owner, BatchHandler) -> plugin.Effect,
  read onUpdate: (Service, Owner, UpdateHandler) -> plugin.Effect,
  read onDraw: (Service, Owner, DrawHandler) -> plugin.Effect,
  read onKey: (Service, Owner, KeyHandler) -> plugin.Effect,
  read onText: (Service, Owner, TextHandler) -> plugin.Effect,
  read onQuit: (Service, Owner, QuitHandler) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

-- Pointing updates resolve hits after the scene and before overlay reactions.
frame.UPDATE_PHASES = table.freeze { 'input', 'scene', 'pointing', 'overlay' } :: { UpdatePhase }

-- Feedback draws beams and landing indicators after all scene and overlay UI.
frame.DRAW_PHASES = table.freeze { 'input', 'scene', 'pointing', 'overlay', 'feedback' } :: { DrawPhase }

-- Retained as the shared subset; new callers use the operation's explicit phase set.
frame.PHASES = frame.UPDATE_PHASES

-- The key and text phases in the order they run.
frame.INPUT_PHASES = table.freeze { 'binding', 'delivery' } :: { InputPhase }

frame.capability = plugin.capability<<Service>> { name = 'lunette/frame', schema = 2 }

return frame
