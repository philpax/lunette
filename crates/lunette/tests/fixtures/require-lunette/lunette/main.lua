-- Requires the native module from LÖVR's own Lua state.
--
-- The host registers `@lunette` in `package.preload` between `luax_preload` and
-- loading `boot.lua`. Nothing else in the suite exercises that state: the unit
-- tests build their own, which proves the module works and not that it was
-- installed where a configuration can reach it.
--
-- Each failure quits with its own status, so the run says which assertion did
-- not hold rather than only that one did not.

function lovr.load()
  local resolved, lunette = pcall(require, '@lunette')
  if not resolved then
    print(lunette)
    lovr.event.quit(11)
    return
  end

  if type(lunette.windows) ~= 'function' or type(lunette.spawn) ~= 'function' then
    lovr.event.quit(12)
    return
  end

  -- No compositor is running, so there is nothing to list. Calling it is the
  -- point: it reads the session the host built before the Lua state existed.
  local windows = lunette.windows()
  if type(windows) ~= 'table' or #windows ~= 0 then
    lovr.event.quit(13)
    return
  end

  lovr.event.quit(9)
end
