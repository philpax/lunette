local lunette = require '@lunette'
local focus = require '@lunette-contracts/focus'

local function misuse(
  service: focus.Service,
  owner: focus.Owner,
  source: focus.Source,
  result: focus.Result,
  activation: focus.Activation,
  handle: focus.TargetHandle
)
  local wrongMode: focus.SourceOptions = { mode = 'keyboard' } -- reject.
  local function oldFocused(): focus.TargetHandle
    return handle
  end
  local oldTarget: focus.SourceOptions = { nativeTarget = oldFocused } -- reject.
  service:newSource({}, { mode = 'physical' }) -- reject.
  source:key(30) -- reject.
  source:key { code = 'a' } -- reject.
  source:key { code = 30, modifiers = { 1 } } -- reject.
  source:key { code = 30, isRepeat = 1 } -- reject.
  source:text(30) -- reject.
  source:text('fixture', 'batch') -- reject.
  source:beginBatch 'batch' -- reject.
  local accepted: boolean = source:key { code = 30 } -- reject.
  local nativeSeat: lunette.Seat = source:keymapSeat() -- reject.
  local unrefined: string = result.message -- reject.
  if result.kind == 'consumed' then
    local absent: string = result.message -- reject.
    assert(#absent > 0)
  end
  local missingMessage: focus.Result = { kind = 'failed' } -- reject.
  local invalidResult: focus.Result = { kind = 'sent' } -- reject.
  source.dead = false -- reject.
  activation.batch = 2 -- reject.
  result.kind = 'unhandled' -- reject.
  return { wrongMode, oldTarget, accepted, nativeSeat, unrefined, missingMessage, invalidResult }
end

local function snapshotMisuse(source: focus.Source, activation: focus.Activation)
  activation.physicalModifiers = nil -- reject.
  if activation.physicalModifiers then
    activation.physicalModifiers.numLock = false -- reject.
    activation.physicalModifiers.control = true -- reject.
  end
  source:key { code = 79, physicalModifiers = false } -- reject.
  source:key { code = 79, physicalModifiers = { shift = false } } -- reject.
  source:key {
    code = 79,
    physicalModifiers = { shift = false, control = false, alt = false, super = false, capsLock = false, numLock = 1 }, -- reject.
  }
end

return { misuse, snapshotMisuse }
