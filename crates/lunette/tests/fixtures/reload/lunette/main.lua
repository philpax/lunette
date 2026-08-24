-- Drives ten soft reloads through the real host. The assertions cover teardown,
-- module identity, callback removal, and the fact that the Lua state survives.
-- Each failure has its own status so the run identifies the assertion that failed.

local lunette = require '@lunette'

local teardown = require '@mullion/teardown'
-- Required so the reload can exercise their teardown hooks and module identity.
local panel = require '@mullion/panel'
require '@mullion/rules'
require '@mullion/signal'
require '@mullion/tag'

-- Ten reloads make accumulation failures observable.
local RELOADS = 10

-- Counts runs after the initial boot.
reloads = reloads or 0

-- Values from the first run, used as reload invariants.
firstFilesystem = firstFilesystem or package.loaded['lovr.filesystem']
firstHooks = firstHooks or table.concat(teardown.pending(), ',')
-- Module tables resolved by successive runs.
panelTables = panelTables or {}
panelTables[#panelTables + 1] = panel

if reloads == 0 then
  -- A callback present only in the first configuration must be removed.
  function lovr.lunwindowopened() end
end

-- Returns the first failed invariant, if any.
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
  if table.concat(teardown.pending(), ',') ~= firstHooks then
    return 14
  end
  if firstHooks == '' then
    return 15
  end
  local count = #panelTables
  if count >= 2 and panelTables[count] == panelTables[count - 1] then
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

-- The reload is asked for from here rather than from `lovr.load`, which is where
-- a key binding would ask for it: `lovr.load` is called by the reload itself, so
-- a configuration reloading from it would be reloading from inside a reload,
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
