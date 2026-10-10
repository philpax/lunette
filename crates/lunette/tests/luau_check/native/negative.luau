local lunette = require '@lunette'

local function misuse(seat: lunette.Seat, sink: lunette.Sink)
  sink:setModifiers({ 'ctrl' }, seat) -- reject.
  seat:symbolFor(30, { 'super' }) -- reject.
end

return misuse
