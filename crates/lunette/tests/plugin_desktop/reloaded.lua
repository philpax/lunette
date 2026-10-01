events.reloadChecks = (events.reloadChecks or 0) + 1
-- Startup enumerates for adoption and for the demonstration terminal, and a
-- reload enumerates for adoption alone: the terminal was already decided.
assert(events.enumerations == events.reloadChecks + 2, 'each reload enumerates exactly once')
assert(_G.lunetteDemonstrationSpawned == true)
assert(#events.spawned == events.startupProcesses, 'reload does not duplicate startup process')
assert(events.closed == 0 and not events.windows[1].dead and not events.windows[2].dead)
assert(subscriptionCount 'onWindowOpened' == 1, 'reload leaves one adoption subscription')
assert(subscriptionCount 'onProcessExited' == 1)
assert(subscriptionCount 'onMonitorAdded' == 1)
assert(subscriptionCount 'onError' == 1)
local seats, claims = 0, 0
for _, seat in ipairs(events.seats) do
  if not seat.dead then
    seats += 1
  end
end
for _, claim in ipairs(events.claims) do
  if not claim.dead then
    claims += 1
  end
end
assert(seats == 2 and claims == 2, 'reload releases the previous resource generation')
lovr.update(0.016)
assert(lovr.draw(events.pass) == false)
