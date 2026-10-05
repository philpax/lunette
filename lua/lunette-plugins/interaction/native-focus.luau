-- Owns one pointer's reusable native focus registration.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local focusContract = require '@lunette-contracts/focus'

local nativeFocus = {}

export type State = {
  seat: lunette.Seat?,
  focusTarget: focusContract.TargetHandle?,
  focusSink: lunette.Sink?,
  focusSeatId: number?,
}

local function sameSink(first: lunette.Sink, second: lunette.Sink): boolean
  if first.dead or second.dead or first.domain ~= second.domain then
    return false
  end
  if first.domain == 'window' then
    return first.id ~= nil and first.id == second.id
  end
  local firstMonitor, secondMonitor = first.monitor, second.monitor
  return firstMonitor ~= nil and secondMonitor ~= nil and firstMonitor.id == secondMonitor.id
end

function nativeFocus.detach(state: State): (() -> ())?
  local target = state.focusTarget
  state.focusTarget, state.focusSink, state.focusSeatId = nil, nil, nil
  return if target
    then function()
      target:destroy()
    end
    else nil
end

function nativeFocus.give(
  state: State,
  sink: lunette.Sink?,
  context: plugin.Context,
  service: focusContract.Service,
  current: () -> boolean
): ()
  local target = state.focusTarget
  if not sink then
    if target and not target.dead then
      target:blur()
    end
    return
  end
  local seat = state.seat or (if sink.domain == 'window' then lunette.defaultSeat() else nil)
  if not current() or sink.dead or (seat and seat.dead) then
    return
  end
  local seatId = seat and seat.id
  local previous = state.focusSink
  if target and not target.dead and state.focusSeatId == seatId and previous and sameSink(previous, sink) then
    target:focus()
    return
  end
  local inverse = nativeFocus.detach(state)
  if inverse then
    inverse()
  end
  if not current() then
    return
  end
  local registered = service:register(context, { kind = 'native', seat = state.seat, sink = sink })
  if not current() then
    registered:destroy()
    return
  end
  state.focusTarget, state.focusSink, state.focusSeatId = registered, sink, seatId
  registered:focus()
end

return nativeFocus
