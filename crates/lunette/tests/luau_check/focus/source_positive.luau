local lunette = require '@lunette'
local focus = require '@lunette-contracts/focus'
local keys = require '@lunette-contracts/keys'

local function message(result: focus.Result): string
  if result.kind == 'failed' then
    local failure: string = result.message
    return failure
  elseif result.kind == 'refused' then
    local refusal: string = result.message
    return refusal
  elseif result.kind == 'consumed' then
    return 'consumed'
  else
    local kind: 'unhandled' = result.kind
    return kind
  end
end

local function consume(service: focus.Service, owner: focus.Owner, window: lunette.Window)
  local virtual: focus.Source = service:newSource(owner, { mode = 'virtual' })
  local nativeOptions: focus.SourceOptions = {
    mode = 'physical',
    nativeTarget = function(): (lunette.Seat?, lunette.Sink?)
      return lunette.defaultSeat(), window.sink
    end,
  }
  local physical: focus.Source = service:newSource(owner, nativeOptions)
  local modifiers: { read [number]: string } = table.freeze { 'shift', 'ctrl' }
  local activation: focus.Activation = { code = 30, modifiers = modifiers, isRepeat = false, batch = 1 }
  local flags: keys.PhysicalModifiers =
    table.freeze { shift = false, control = false, alt = false, super = false, capsLock = false, numLock = true }
  local keypad: focus.Activation = { code = 79, physicalModifiers = flags, batch = 1 }
  local keypadResult: focus.Result = physical:key(keypad)
  assert(keypadResult.kind ~= 'failed')
  virtual:beginBatch(1)
  local keyResult: focus.Result = virtual:key(activation)
  local textResult: focus.Result = physical:text('fixture', 1)
  local seat: lunette.Seat? = virtual:keymapSeat()
  if seat and not seat.dead then
    local symbol: number? = seat:symbolFor(activation.code, {})
    assert(symbol == nil or symbol >= 0)
  end
  local reset: boolean = virtual:reset()
  local destroyed: boolean = physical:destroy()
  return { key = message(keyResult), text = message(textResult), reset = reset, destroyed = destroyed }
end

return consume
