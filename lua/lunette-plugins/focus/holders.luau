-- Tracks each owner's keyboard focus grant and withdraws it without clearing a later owner's grant.

local lunette = require '@lunette'

local focus = {}

export type Holder = {
  seat: lunette.Seat?,
  sink: lunette.Sink?,
}

export type Focus = {
  current: Holder?,
  seats: { [lunette.Seat]: Holder },
}

function focus.new(): Focus
  return { current = nil, seats = {} }
end

function focus.holder(): Holder
  return { seat = nil, sink = nil }
end

-- Clears the holder state before native withdrawal so a failed call leaves no active grant.
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

-- Applies native focus before recording the grant, preserving prior state if the seat rejects it.
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

-- Attempts every seat withdrawal before raising the combined failures.
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
