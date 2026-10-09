-- Asserts that a configuration cannot overwrite the module roots, through `@lunette-plugin`.
-- Each failure quits with its own status, so the run reports which assertion did not hold.

-- Requires the root module and checks it is the copy the run meant.
--
-- Compares module contents, because PhysFS reports the supplied mount point rather than which tree answered.
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

-- Asserts that a configuration cannot overwrite a module root. The write lands in the save directory, which is mounted behind the module roots.
local function checkReadOnly(marker)
  local _, status = loadRoot(marker)
  if status ~= 9 then
    return status
  end

  lovr.filesystem.createDirectory '@lunette-plugin'
  lovr.filesystem.write('@lunette-plugin/init.luau', 'return { overwritten = true }\n')

  -- Forces the require below through the search path, not the cached table.
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
  local marker = arg[2]
  lovr.event.quit(marker and checkReadOnly(marker) or 15)
end
