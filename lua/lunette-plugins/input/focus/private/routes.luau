-- The current keyboard route and native seat authority have separate lifetimes.

local contract = require '@lunette-contracts/focus'
local lunette = require '@lunette'

local routes = {}

export type Route = { target: contract.Target? }
export type Authority = { route: Route, seat: lunette.Seat }
export type State = {
  current: Route?,
  revision: number,
  failed: boolean,
  seats: { [number]: Authority },
  pending: { [number]: Authority },
}

function routes.new(): State
  return { current = nil, revision = 0, failed = false, seats = {}, pending = {} }
end

local function live(target: contract.Target?): boolean
  if not target then
    return false
  end
  if target.kind == 'local' then
    return true
  end
  return not target.sink.dead and (not target.seat or not target.seat.dead)
end

local function authoritySeat(target: contract.Target): lunette.Seat?
  if target.kind ~= 'native' or target.sink.domain ~= 'window' then
    return nil
  end
  return target.seat or lunette.defaultSeat()
end

-- Bookkeeping clears before the inverse; a refused clear cannot resurrect an old route.
local function clearSeat(state: State, route: Route): boolean
  local cleared = false
  local failures: { string } = {}
  local authorities = table.clone(state.seats)
  for id, authority in pairs(state.pending) do
    if authority.route == route then
      authorities[id] = authority
    end
  end
  for id, authority in pairs(authorities) do
    if authority.route == route then
      if state.seats[id] and state.seats[id].route == route then
        state.seats[id] = nil
      end
      if state.pending[id] and state.pending[id].route == route then
        state.pending[id] = nil
      end
      cleared = true
      if not authority.seat.dead then
        local ok, result = pcall(function(): boolean
          return authority.seat:setFocus(nil)
        end)
        if not ok or result == false then
          failures[#failures + 1] = if ok then 'seat ' .. id .. ' refused focus clear' else tostring(result)
        end
      end
    end
  end
  if #failures > 0 then
    state.failed = true
    error('focus: native withdrawal: ' .. table.concat(failures, '; '), 0)
  end
  return cleared
end

function routes.focus(state: State, route: Route, eligible: () -> boolean): boolean
  local target = route.target
  if not eligible() or not live(target) or not target then
    return false
  end
  if state.current == route then
    return true
  end
  local revision = state.revision
  local seat = authoritySeat(target)
  if target.kind == 'native' and target.sink.domain == 'window' then
    if not seat or seat.dead then
      return false
    end
    local pending: Authority = { route = route, seat = seat }
    -- Keep both prior and in-flight authority visible to synchronous lock listeners.
    state.pending[seat.id] = pending
    local ok, accepted = pcall(function(): boolean
      return seat:setFocus(target.sink)
    end)
    if not ok then
      state.failed = true
      clearSeat(state, route)
      error(accepted, 0)
    end
    if state.pending[seat.id] ~= pending then
      return false
    end
    if not accepted then
      state.pending[seat.id] = nil
      return false
    end
  end
  if state.revision ~= revision or route.target ~= target or not live(target) or not eligible() then
    clearSeat(state, route)
    return false
  end
  local previous = state.current
  state.current = route
  state.revision += 1
  if seat then
    state.pending[seat.id] = nil
    state.seats[seat.id] = { route = route, seat = seat }
  end
  if target.kind == 'local' and previous then
    clearSeat(state, previous)
  end
  return true
end

function routes.blur(state: State, route: Route): boolean
  local current = state.current == route
  if current then
    state.current = nil
    state.revision += 1
  end
  local cleared = clearSeat(state, route)
  return current or cleared
end

function routes.current(state: State): Route?
  local current = state.current
  return if current and live(current.target) then current else nil
end

return routes
