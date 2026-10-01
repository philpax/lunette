-- The frame service contract.
--
-- The provider dispatches LÖVR's frame and input callbacks to handlers that
-- plugins register. Every registration is owner-scoped: it lasts until the
-- returned effect is disposed or its owner unloads.
--
-- Update and draw handlers run phase by phase in the order PHASES lists, and
-- within a phase by ascending order, then by registration. The phases are:
--
-- input: reads devices and input state before the scene moves; in a draw,
-- what is drawn beneath everything else.
-- scene: the panels and other surfaces the scene is made of.
-- pointing: what picks against or points at the scene, such as lasers, which
-- read this frame's surface poses.
-- overlay: what is drawn over everything else, such as an error display.
--
-- Key and text handlers run binding handlers before delivery handlers, then
-- by ascending order and registration. A handler that answers true consumes
-- the event, and the handlers after it do not see it. A binding is a hotkey or
-- other interception; delivery is forwarding to a client. Key and text are
-- separate streams: LÖVR reports a printable key as a key press and as text,
-- so consuming one does not consume the other.
--
-- Every handler runs under its own protected call. A handler's error is
-- reported through lunette.reportError, and the handlers after it still run;
-- a key or text handler that raises does not consume the event. Quit handlers
-- run in registration order and cannot veto the quit.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'

local frame = {}

export type Owner = owner.Owner
export type Phase = 'input' | 'scene' | 'pointing' | 'overlay'
export type InputPhase = 'binding' | 'delivery'

-- What lovr.keypressed reports. isRepeat is LÖVR's isrepeat argument; repeat
-- is a reserved word, so a field of that name could not be read as one.
export type KeyEvent = {
  read key: KeyCode,
  read scancode: number,
  read isRepeat: boolean,
}

-- What lovr.textinput reports: the text and its first code point.
export type TextEvent = {
  read text: string,
  read code: number,
}

export type UpdateHandler = {
  read phase: Phase,
  read order: number?,
  read run: (number) -> (),
}

export type DrawHandler = {
  read phase: Phase,
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

export type Service = {
  read onUpdate: (Service, Owner, UpdateHandler) -> plugin.Effect,
  read onDraw: (Service, Owner, DrawHandler) -> plugin.Effect,
  read onKey: (Service, Owner, KeyHandler) -> plugin.Effect,
  read onText: (Service, Owner, TextHandler) -> plugin.Effect,
  read onQuit: (Service, Owner, QuitHandler) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

-- The phases in the order update and draw run them.
frame.PHASES = table.freeze { 'input', 'scene', 'pointing', 'overlay' } :: { Phase }

-- The key and text phases in the order they run.
frame.INPUT_PHASES = table.freeze { 'binding', 'delivery' } :: { InputPhase }

frame.capability = plugin.capability<<Service>> { name = 'lunette/frame', schema = 1 }

return frame
