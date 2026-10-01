-- Keyboard focus that grants hold through one focus activation.
--
-- Focus is held, not merely set. A holder is one grant an owner holds for a
-- seat through setFocus, and a holder that ends takes back what it gave: the seat it focused
-- is withdrawn natively, and the service stops answering it as the focused
-- seat. A holder that gave a seat's focus away to a later holder takes back
-- nothing. The native seat and the answer the service gives therefore never
-- name a focus whose holder has gone.

local lunette = require '@lunette'

local focus = {}

-- A holder's identity is its table. It records what it last granted.
export type Holder = {
  seat: lunette.Seat?,
  sink: lunette.Sink?,
}

export type Focus = {
  -- The holder the service answers as focused.
  current: Holder?,
  -- The holder whose sink each seat was last given.
  seats: { [lunette.Seat]: Holder },
}

function focus.new(): Focus
  return { current = nil, seats = {} }
end

function focus.holder(): Holder
  return { seat = nil, sink = nil }
end

-- Takes back what a holder granted. Lua state is cleared before the native
-- withdrawal, so a withdrawal that raises leaves no holder answered.
function focus.revoke(state: Focus, holder: Holder): ()
  local seat = holder.seat
  holder.seat, holder.sink = nil, nil
  if state.current == holder then
    state.current = nil
  end
  if seat and state.seats[seat] == holder then
    state.seats[seat] = nil
    if not seat.dead then
      seat:setFocus(nil)
    end
  end
end

-- Gives a seat's keyboard to a sink on behalf of a holder. A nil sink
-- withdraws the holder's focus. The native call is made first, so a seat that
-- refuses leaves the Lua state as it was.
function focus.grant(state: Focus, holder: Holder, seat: lunette.Seat?, sink: lunette.Sink?): ()
  if not sink then
    focus.revoke(state, holder)
    return
  end
  if holder.seat and holder.seat ~= seat then
    focus.revoke(state, holder)
  end
  if seat and not seat.dead then
    seat:setFocus(sink)
  end
  holder.seat, holder.sink = seat, sink
  if seat then
    state.seats[seat] = holder
  end
  state.current = holder
end

function focus.focused(state: Focus): (lunette.Seat?, lunette.Sink?)
  local holder = state.current
  if not holder then
    return nil, nil
  end
  local seat, sink = holder.seat, holder.sink
  if (seat and seat.dead) or (sink and sink.dead) then
    return nil, nil
  end
  return seat, sink
end

-- Takes back every grant, for the activation's end. Every seat is attempted
-- before a failure is raised.
function focus.clear(state: Focus): ()
  local holders: { Holder } = {}
  for _, holder in pairs(state.seats) do
    holders[#holders + 1] = holder
  end
  local failures: { string } = {}
  for _, holder in ipairs(holders) do
    local ok, failure = pcall(focus.revoke, state, holder)
    if not ok then
      failures[#failures + 1] = tostring(failure)
    end
  end
  state.current = nil
  if #failures > 0 then
    error('focus: withdrawal: ' .. table.concat(failures, '; '), 0)
  end
end

return focus
