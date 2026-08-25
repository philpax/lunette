-- A reload whose configuration raises leaves the session running.
--
-- Safe mode is for a `main.lua` that fails to load at startup. A reload that
-- fails is a different case and deliberately does not fall into it: the user has
-- a working session in front of them, so the error is reported, the session
-- keeps running, and the next reload works. This fixture is that sequence.
--
-- The second run raises, which stands in for the user saving a file with a
-- defect in it. Globals survive a soft reload, so the run counter is how this
-- one file is three different configurations in turn.

local lunette = require '@lunette'

runs = (runs or 0) + 1

if runs == 2 then
  error('a deliberate defect in the configuration')
end

function lovr.load()
  if runs == 3 then
    -- Reached only because the failed reload left the session running.
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

  -- The Lua state is still running and still reloadable, which is the whole
  -- difference between this and safe mode.
  local recovered, recoveredMessage = lunette.reload()
  if not recovered then
    print('lunette: the session did not recover: ' .. tostring(recoveredMessage))
    lovr.event.quit(13)
  end
end
