-- Checks the standard-library mount through the real host. The mode and marker
-- arrive as the first two user arguments after boot.lua shifts them into `arg`.

-- Requires the standard library, and checks it is the copy the run meant.
--
-- The check is on the module's contents rather than on the path it came from:
-- physfs reports the mount point it was handed, and a test comparing paths would
-- be asserting how a temporary directory was spelled rather than which tree
-- answered.
local function loadMullion(marker)
  local resolved, mullion = pcall(require, '@mullion')
  if not resolved then
    print(mullion)
    return nil, 11
  end

  if type(mullion) ~= 'table' then
    return nil, 12
  end

  if marker and mullion[marker] ~= true then
    print('the root module carries no ' .. marker .. ' field, so it is not the expected copy')
    return nil, 13
  end

  return mullion, 9
end

-- Asserts that nothing is mounted, which is what an uninstalled standard library
-- looks like. A session that needs none of it still has to boot, so this is the
-- supported case rather than a failure.
local function checkAbsent()
  if pcall(require, '@mullion') then
    return 16
  end

  return 9
end

-- Asserts a configuration cannot overwrite the standard library it is running on
-- top of. The write lands in the save directory, which is mounted behind the
-- standard library, so a fresh require still loads the original.
local function checkReadOnly(marker)
  local _, status = loadMullion(marker)
  if status ~= 9 then
    return status
  end

  lovr.filesystem.createDirectory('@mullion')
  lovr.filesystem.write('@mullion/init.lua', 'return { overwritten = true }\n')

  -- Dropped so that the require below resolves through the search path again
  -- rather than returning the cached table.
  package.loaded['@mullion'] = nil

  local reloaded, reloadedStatus = loadMullion(marker)
  if reloadedStatus ~= 9 then
    return reloadedStatus
  end

  if reloaded.overwritten then
    print('the write reached the mounted standard library')
    return 14
  end

  return 9
end

function lovr.load()
  local mode, marker = arg[1], arg[2]

  local status
  if mode == 'present' then
    local _, result = loadMullion(marker)
    status = result
  elseif mode == 'absent' then
    status = checkAbsent()
  elseif mode == 'readOnly' then
    status = marker and checkReadOnly(marker) or 15
  else
    print('unknown mode ' .. tostring(mode))
    status = 15
  end

  lovr.event.quit(status)
end
