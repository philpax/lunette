-- Ten soft reloads, from inside a session.
--
-- `lunette.reload()` shuts down plugin runtimes, clears user and standard-library modules from `package.loaded`, clears configuration callbacks, and reruns the configuration. These effects require the host-registered module roots and the file resolved by `boot.lua`.
--
-- Globals survive a soft reload: the Lua state stays open, and the reload
-- removes the configuration's modules and callbacks. One file can drive several
-- reloads and compare what it saw across them.
--
-- Each failure quits with its own status, so the run reports which assertion
-- did not hold. A shared status would not name the failed assertion.

local lunette = require '@lunette'

-- Reloads rerun shipped Lua root module bodies and create fresh tables; prior-run tables do not persist.
local vocabulary = require '@lunette-contracts/vocabulary'

-- Ten reloads expose accumulation across repeated runs; one reload cannot show that state accumulates.
local RELOADS = 10

-- The reload count excludes the initial run by `boot.lua`.
reloads = reloads or 0

-- What the first run saw, to compare every later run against.
firstFilesystem = firstFilesystem or package.loaded['lovr.filesystem']
-- The `@lunette-contracts/vocabulary` module table each run resolved, newest
-- last.
vocabularyTables = vocabularyTables or {}
vocabularyTables[#vocabularyTables + 1] = vocabulary

if reloads == 0 then
  -- Defined by the first run alone. It models a callback the user deleted
  -- from their configuration between two reloads: a reload that left it bound
  -- would keep calling code that is no longer in the file.
  function lovr.lunwindowopened() end
end

-- The status the run should quit with, or nothing when everything held.
local function firstFailure()
  if package.loaded['lovr.filesystem'] ~= firstFilesystem then
    return 11
  end
  if lovr.log == nil or lovr.run == nil then
    return 12
  end
  if reloads >= 1 and lovr.lunwindowopened ~= nil then
    return 13
  end
  local count = #vocabularyTables
  if count >= 2 and vocabularyTables[count] == vocabularyTables[count - 1] then
    return 16
  end
  return nil
end

function lovr.load()
  local failure = firstFailure()
  if failure then
    print('lunette: assertion ' .. failure .. ' did not hold at reload ' .. reloads)
    lovr.event.quit(failure)
  end
end

-- The reload is initiated from here, not from `lovr.load`, where a key binding
-- would ask for it. `lovr.load` is called by the reload itself, so a
-- configuration reloading from it would be reloading from inside a reload,
-- which is refused.
function lovr.update()
  if reloads >= RELOADS then
    lovr.event.quit(9)
    return
  end

  reloads = reloads + 1
  local reloaded, message = lunette.reload()
  if not reloaded then
    print('lunette: the reload failed: ' .. tostring(message))
    lovr.event.quit(17)
  end
end
