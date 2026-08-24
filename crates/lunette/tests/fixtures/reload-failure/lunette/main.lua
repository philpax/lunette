-- A failed reload leaves the running session usable and reloadable. The run
-- counter makes this file act as the initial configuration, the defective reload,
-- and the recovered configuration.

local lunette = require '@lunette'

runs = (runs or 0) + 1

if runs == 2 then
  error('a deliberate defect in the configuration')
end

function lovr.load()
  if runs == 3 then
    -- The failed reload left the session running.
    lovr.event.quit(9)
    return
  end

  local reloaded, message = lunette.reload()
  if reloaded then
    print('lunette: the reload should have failed')
    lovr.event.quit(11)
    return
  end
  if type(message) ~= 'string' or not message:find('a deliberate defect', 1, true) then
    print('lunette: the message did not name the defect: ' .. tostring(message))
    lovr.event.quit(12)
    return
  end

  -- The Lua state remained running and reloadable after the failure.
  local recovered, recoveredMessage = lunette.reload()
  if not recovered then
    print('lunette: the session did not recover: ' .. tostring(recoveredMessage))
    lovr.event.quit(13)
  end
end
