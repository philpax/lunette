-- Requires the native module from the Lua state created by the real host. The
-- host registers it in `package.preload` before loading `boot.lua`.

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
