local lunette = require '@lunette'
local focus = require '@lunette-contracts/focus'

local function misuse(
  service: focus.Service,
  owner: focus.Owner,
  receiver: focus.Receiver,
  target: focus.Target,
  handle: focus.TargetHandle,
  change: focus.Change,
  event: focus.KeyEvent,
  sink: lunette.Sink
)
  local function numberKey(_event: focus.KeyEvent): number
    return 1
  end
  local function handleChange(_target: focus.TargetHandle): () end
  local function revisionChange(_revision: number): () end
  local keyReturnsNumber: focus.Receiver = { key = numberKey, text = receiver.text } -- reject.
  local textReturnsNil: focus.Receiver = { key = receiver.key, text = function(_text: string): () end } -- reject.
  local wrongFocus: focus.Receiver = { key = receiver.key, text = receiver.text, onFocus = handleChange } -- reject.
  local wrongBlur: focus.Receiver = { key = receiver.key, text = receiver.text, onBlur = revisionChange } -- reject.
  local missingReceiver: focus.Target = { kind = 'local', wantsKeyboard = true } -- reject.
  local wrongKeyboard: focus.Target = { kind = 'local', receiver = receiver, wantsKeyboard = 'yes' } -- reject.
  local missingSink: focus.Target = { kind = 'native', seat = lunette.defaultSeat() } -- reject.
  local wrongKind: focus.Target = { kind = 'remote', sink = sink } -- reject.
  service:register({}, target) -- reject.
  service:register(owner, sink) -- reject.
  service:onChanged(owner, { run = function(_revision: number): () end }) -- reject.
  service:focused(owner) -- reject.
  local nativePair: lunette.Seat = handle -- reject.
  handle.dead = false -- reject.
  change.revision = 2 -- reject.
  change.target = nil -- reject.
  event.code = 1 -- reject.
  event.modifiers[1] = 'ctrl' -- reject.
  event.source = 'physical' -- reject.
  event.isRepeat = true -- reject.
  receiver.key = receiver.key -- reject.
  target.kind = 'native' -- reject.
  return {
    keyReturnsNumber,
    textReturnsNil,
    wrongFocus,
    wrongBlur,
    missingReceiver,
    wrongKeyboard,
    missingSink,
    wrongKind,
    nativePair,
  }
end

return misuse
