-- Asserts that the file-backed module roots are mounted from the requested
-- directory, through the plugin facade's root, `@lunette-plugin`.
--
-- The host wraps LÖVR's `lovr.filesystem` loader so the module roots are
-- mounted between the module being created and `main.luau` running; see
-- crates/lunette/src/boot.rs. Nothing else in the suite exercises that, and it
-- is not observable from a Lua state a test builds, because the mount goes into
-- LÖVR's virtual filesystem, not into the process's.
--
-- The mode arrives as the first user argument, which boot.lua shifts to arg[1],
-- and a marker field the mounted root module is expected to carry arrives as
-- arg[2]. Each failure quits with its own status, so the run reports which
-- assertion did not hold. A shared status would not name the failed assertion.

-- Requires the root module, and checks it is the copy the run meant.
--
-- The check compares module contents. Physfs reports the supplied mount point,
-- so comparing paths would test temporary-directory spelling, not which tree answered.
local function loadRoot(marker)
  local resolved, root = pcall(require, '@lunette-plugin')
  if not resolved then
    print(root)
    return nil, 11
  end

  if type(root) ~= 'table' then
    return nil, 12
  end

  if marker and root[marker] ~= true then
    print('the root module carries no ' .. marker .. ' field, so it is not the expected copy')
    return nil, 13
  end

  return root, 9
end

-- Asserts that no root is mounted, the condition of a missing or broken
-- installation. The session continues into safe mode, where `require` reports
-- the missing root.
local function checkAbsent()
  if pcall(require, '@lunette-plugin') then
    return 16
  end

  return 9
end

-- Asserts that a configuration cannot overwrite a module root it runs on. The
-- write lands in the save directory, which is mounted behind the module roots,
-- so a fresh require still loads the original.
local function checkReadOnly(marker)
  local _, status = loadRoot(marker)
  if status ~= 9 then
    return status
  end

  lovr.filesystem.createDirectory '@lunette-plugin'
  lovr.filesystem.write('@lunette-plugin/init.luau', 'return { overwritten = true }\n')

  -- The dropped entry makes the require below resolve through the search path
  -- again, not through the cached table.
  package.loaded['@lunette-plugin'] = nil

  local reloaded, reloadedStatus = loadRoot(marker)
  if reloadedStatus ~= 9 then
    return reloadedStatus
  end

  if reloaded.overwritten then
    print 'the write reached the mounted module root'
    return 14
  end

  return 9
end

function lovr.load()
  local mode, marker = arg[1], arg[2]

  local status
  if mode == 'present' then
    local _, result = loadRoot(marker)
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
