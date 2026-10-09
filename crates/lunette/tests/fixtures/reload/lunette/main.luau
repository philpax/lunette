-- Ten soft reloads, from inside a session.
--
-- Globals survive a soft reload, so one file drives several reloads and
-- compares what each run saw. Each failure quits with its own status, so the
-- run reports which assertion did not hold.

local lunette = require '@lunette'

-- Reloads rerun module bodies, so each run resolves a fresh table.
local vocabulary = require '@lunette-contracts/vocabulary'

-- One reload cannot show that state accumulates across runs.
local RELOADS = 10

-- The reload count excludes the initial run by `boot.lua`.
reloads = reloads or 0

firstFilesystem = firstFilesystem or package.loaded['lovr.filesystem']
vocabularyTables = vocabularyTables or {}
vocabularyTables[#vocabularyTables + 1] = vocabulary

if reloads == 0 then
  -- Defined by the first run alone, modelling a callback the user deleted
  -- between two reloads.
  function lovr.lunwindowopened() end
end

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

-- The reload starts here, not from `lovr.load`, because the reload itself calls
-- `lovr.load` and a reload from inside a reload is refused.
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
