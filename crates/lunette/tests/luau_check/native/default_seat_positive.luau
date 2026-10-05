local lunette = require '@lunette'

local function consume(window: lunette.Window)
  local seat: lunette.Seat? = lunette.defaultSeat()
  if seat == nil or seat.dead then
    return false
  end
  local id: number = seat.id
  local name: string = seat.name
  local sink: lunette.Sink? = window.sink
  local focused: boolean = seat:setFocus(sink)
  local symbol: number? = seat:symbolFor(30, {})
  local character: string? = seat:characterFor(30, {})
  assert(id >= 0 and #name > 0 and (symbol == nil or symbol >= 0))
  return focused and (character == nil or #character > 0)
end

return consume
