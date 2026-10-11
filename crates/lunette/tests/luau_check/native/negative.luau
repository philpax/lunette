local lunette = require '@lunette'

local function misuse(seat: lunette.Seat, sink: lunette.Sink, window: lunette.Window)
  local pid: number = window.process -- reject.
  local windows: { lunette.Window } = lunette.processes() -- reject.
  assert(pid > 0 and #windows > 0)
  sink:setModifiers({ 'ctrl' }, seat) -- reject.
  seat:symbolFor(30, { 'super' }) -- reject.
end

return misuse
