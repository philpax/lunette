-- The native declarations accept what the runtime accepts.
local lunette = require '@lunette'

local function exercise(window: lunette.Window, seat: lunette.Seat, sink: lunette.Sink): boolean
  local names: { lunette.ModifierName } = lunette.modifierNames()
  local processes: { lunette.Process } = lunette.processes()
  local process: lunette.Process? = window.process
  assert(#processes >= 0 and (process == nil or process.id > 0))
  return window:setProperty('example.key', nil)
    and sink:setModifiers({ 'control', 'logo' }, seat)
    and seat:symbolFor(30, names) ~= nil
    and #names > 0
end

local seat = lunette.newSeat { name = 'example', layout = 'us' }

lunette.onMonitorAdded(function(event: lunette.MonitorAddedEvent)
  local monitor: lunette.Monitor = event.monitor
  assert(not monitor.dead)
end)

lunette.onProcessExited(function(event: lunette.ProcessExitedEvent)
  local dead: boolean = event.process.dead
  assert(dead)
end)

return { exercise = exercise, seat = seat }
