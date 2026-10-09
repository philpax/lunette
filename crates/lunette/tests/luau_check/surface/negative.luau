local lunette = require '@lunette'
local interaction = require '@lunette-contracts/interaction'
local vocabulary = require '@lunette-contracts/vocabulary'

type PointerEvent = interaction.PointerEvent
type PointerButton = lunette.PointerButton
type CancelReason = interaction.CancelReason
type ProjectWrong = (vocabulary.Surface, vector, vector) -> (number?, string?, number?)

local function misuse(target: vocabulary.Surface, pointer: vocabulary.Pointer, event: PointerEvent)
  local invalidButton: PointerButton = 'center' -- reject.
  local invalidKind: PointerEvent = { kind = 'hover', pointer = pointer, captured = false, inside = false } -- reject.
  local invalidReason: CancelReason = 'timeout' -- reject.
  pointer:cancel(target, 'timeout') -- reject.
  local invalidCoordinates: PointerEvent =
    { kind = 'enter', pointer = pointer, x = 'left', captured = false, inside = true } -- reject.
  local invalidDeltas: PointerEvent =
    { kind = 'scroll', pointer = pointer, dx = 0, dy = 'down', captured = false, inside = true } -- reject.

  local wrongProjectResult: vocabulary.Surface = { -- reject.
    kind = nil,
    dead = false,
    raycast = function(
      _self: vocabulary.Surface,
      _origin: vector,
      _direction: vector,
      _captured: boolean?
    ): (number?, number?, number?)
      return nil, nil, nil
    end,
    project = function(_self: vocabulary.Surface, _origin: vector, _direction: vector): (number?, string?, number?)
      return nil, 'invalid', nil
    end,
  }
  local wrongCallbackReceiver: vocabulary.Surface = { -- reject.
    kind = nil,
    dead = false,
    raycast = function(
      _self: vocabulary.Surface,
      _origin: vector,
      _direction: vector,
      _captured: boolean?
    ): (number?, number?, number?)
      return nil, nil, nil
    end,
    onPointer = function(_self: interaction.Pointer, _event: PointerEvent): () end,
  }

  event.x = 1 -- reject.
  target.dead = true -- reject.
  pointer.distance = 1 -- reject.
  local wrongProject: ProjectWrong = function(
    _self: vocabulary.Surface,
    _origin: vector,
    _direction: vector
  ): (number?, string?, number?)
    return nil, 'invalid', nil
  end
  target.project = wrongProject -- reject.

  local missingMetadata: PointerEvent = { kind = 'enter', pointer = pointer, captured = false } -- reject.
  local missingButton: PointerEvent = { kind = 'press', pointer = pointer, captured = false, inside = true } -- reject.
  local missingDeltas: PointerEvent = { kind = 'scroll', pointer = pointer, captured = false, inside = true, dx = 0 } -- reject.
  local missingReason: PointerEvent =
    { kind = 'cancel', pointer = pointer, captured = false, inside = true, button = 'left' } -- reject.

  local invalidScrollButton: PointerButton? = nil
  local invalidReleaseReason: CancelReason? = nil
  if event.kind == 'scroll' then
    invalidScrollButton = event.button -- reject.
  elseif event.kind == 'release' then
    invalidReleaseReason = event.reason -- reject.
  end

  return {
    invalidButton = invalidButton,
    invalidKind = invalidKind,
    invalidReason = invalidReason,
    invalidCoordinates = invalidCoordinates,
    invalidDeltas = invalidDeltas,
    wrongProjectResult = wrongProjectResult,
    wrongCallbackReceiver = wrongCallbackReceiver,
    missingMetadata = missingMetadata,
    missingButton = missingButton,
    missingDeltas = missingDeltas,
    missingReason = missingReason,
    invalidScrollButton = invalidScrollButton,
    invalidReleaseReason = invalidReleaseReason,
  }
end

return misuse
