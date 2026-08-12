-- Ten soft reloads, from inside a real session.
--
-- `lunette.reload()` runs the standard library's teardown hooks, clears
-- `package.loaded` for the user's and the standard library's namespaces, clears
-- the callbacks this file owns, and runs this file again. Everything asserted
-- here is about that, and none of it is observable from a unit test on a Lua
-- state a test built: the module has to be the one the host registered, the
-- standard library has to be the one the host mounted, and `main.lua` has to be
-- the file boot.lua resolved.
--
-- Globals survive a soft reload — the Lua state is not closed, only the
-- configuration's modules and callbacks go — which is what lets one file drive
-- several reloads and compare what it saw across them.
--
-- Each failure quits with its own status, so the run says which assertion did
-- not hold rather than only that one did not.

local lunette = require '@lunette'

local teardown = require '@mullion/teardown'
-- Required for their teardown hooks and their module identity, which are the
-- two things a reload has to leave in a stated state.
local panel = require '@mullion/panel'
require '@mullion/rules'
require '@mullion/signal'
require '@mullion/tag'

-- How many reloads this fixture performs. Ten, because AC5.4 is about
-- accumulation and one reload cannot show that nothing accumulates.
local RELOADS = 10

-- How many times this file has been run by a reload rather than by boot.lua.
reloads = reloads or 0

-- What the first run saw, to compare every later run against.
firstFilesystem = firstFilesystem or package.loaded['lovr.filesystem']
firstHooks = firstHooks or table.concat(teardown.pending(), ',')
-- The `@mullion/panel` module table each run resolved, newest last.
panelTables = panelTables or {}
panelTables[#panelTables + 1] = panel

if reloads == 0 then
  -- Defined by the first run alone, which stands in for a callback the user
  -- deleted from their configuration between two reloads. A reload that left it
  -- bound would keep calling code that is no longer in the file.
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
