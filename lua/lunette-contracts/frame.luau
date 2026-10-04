-- Handlers run by phase, order, and registration. A key or text handler that returns true consumes the event.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'

local frame = {}

export type Owner = owner.Owner
export type Phase = 'input' | 'scene' | 'pointing' | 'overlay'
export type InputPhase = 'binding' | 'delivery'

-- What lovr.keypressed reports. `isRepeat` is LÖVR's isrepeat, renamed because `repeat` is reserved.
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
