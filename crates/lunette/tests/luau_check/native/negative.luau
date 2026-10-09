local lunette = require '@lunette'

local function misuse(seat: lunette.Seat, sink: lunette.Sink)
  sink:setModifiers({ 'ctrl' }, seat) -- reject.
  seat:setModifiers {} -- reject.
  sink:modifiers({}, seat) -- reject.
  seat:symbolFor(30, { 'super' }) -- reject.
end

lunette.newSeat 'example' -- reject.
lunette.onTitleChanged(function() end) -- reject.
lunette.onLayerGranted(function() end) -- reject.
lunette.onLayerRevoked(function() end) -- reject.
lunette.onMonitorAdded(function(event)
  local _id = event.id -- reject.
end)
lunette.onProcessExited(function(event)
  local _alive = event.process.alive -- reject.
  local _external = event.process.external -- reject.
end)

return misuse
