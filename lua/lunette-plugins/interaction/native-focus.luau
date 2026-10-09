-- Owns one pointer's reusable native focus registration.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local focusContract = require '@lunette-contracts/focus'

local nativeFocus = {}

export type State = {
  seat: lunette.Seat?,
  focusTarget: focusContract.TargetHandle?,
  focused: focusContract.Target?,
}

function nativeFocus.detach(state: State): (() -> ())?
  local target = state.focusTarget
  state.focusTarget, state.focused = nil, nil
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
  -- The comparison resolves the seat now, so a changed default seat replaces the registration.
  local resolved: focusContract.Target = { kind = 'native', seat = seat, sink = sink }
  local previous = state.focused
  if
    target
    and not target.dead
    and previous
    and previous.kind == 'native'
    and not previous.sink.dead
    and focusContract.sameNative(previous, resolved)
  then
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
  state.focusTarget, state.focused = registered, resolved
  registered:focus()
end

return nativeFocus
