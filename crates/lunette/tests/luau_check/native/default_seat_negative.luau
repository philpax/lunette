local lunette = require '@lunette'

local function misuse()
  local required: lunette.Seat = lunette.defaultSeat() -- reject.
  lunette.defaultSeat 'fixture' -- reject.
  local seat: lunette.Seat? = lunette.defaultSeat()
  local optionalId: number = seat.id -- reject.
  if seat then
    seat.id = 2 -- reject.
  end
  return { required = required, optionalId = optionalId }
end

return misuse
