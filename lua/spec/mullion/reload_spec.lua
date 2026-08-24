-- Every module is safe to require twice.
--
-- A soft reload discards the Lua state and runs every module body again
-- (docs/lua-api.md#reload). A timer, signal connection, or teardown hook that
-- leaks across it is a defect, so this walks the tree, requires every module
-- twice, and counts what accumulated.
--
-- The second pass keeps one `mullion.teardown` and replaces everything else, so
-- the registry the two passes register into is the same one. That is the shape a
-- reload has, and a module that appended rather than replaced would leave two
-- hooks under one name here.
--
-- Nothing this case does reaches the module tables the rest of the suite holds:
-- the copies it makes are its own, and `package.loaded` is put back the way it
-- was found before the case returns.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local tree = require '@spec/mullion/tree'

local spec = suite.new 'mullion.reload'

-- Every module name, in the order the tree lists them.
local function moduleNames()
  local names = {}
  for _, path in ipairs(tree.modules()) do
    names[#names + 1] = tree.moduleName(path)
  end
  return names
end

-- What `package.loaded` holds for each of `names`, so the case can put it back.
local function snapshot(names)
  local held = {}
  for _, name in ipairs(names) do
    held[name] = package.loaded[name]
  end
  return held
end

local function restore(held)
  for name, module in pairs(held) do
    package.loaded[name] = module
  end
end

-- Requires every module named, having first dropped whatever `package.loaded`
-- held for it, so that each module body runs again. `keep` names the one module
-- that is not dropped.
local function requireAll(names, keep)
  for _, name in ipairs(names) do
    if name ~= keep then
      package.loaded[name] = nil
    end
  end
  for _, name in ipairs(names) do
    require(name)
  end
end

-- How many names appear more than once in `pending`, as a report.
local function duplicates(pending)
  local seen, repeated = {}, {}
  for _, name in ipairs(pending) do
    if seen[name] then
      repeated[#repeated + 1] = name
    end
    seen[name] = true
  end
  return table.concat(repeated, ', ')
end

spec('requiring every module twice leaves one teardown hook each', function()
  local names = moduleNames()
  local held = snapshot(names)

  local ok, raised = pcall(function()
    -- The first pass builds a registry of its own, so the counts below are
    -- about this case rather than about whatever the rest of the suite has
    -- registered.
    requireAll(names)
    local teardown = require '@mullion/teardown'
    local first = teardown.pending()

    -- The second pass keeps that registry and re-runs every other module body,
    -- which is what a soft reload does.
    -- Named as the tree names it. A name in any other form matches nothing,
    -- which would clear the registry the first pass filled and leave the two
    -- passes reading different ones — and the local above still holds the
    -- first, so every assertion below would compare it against itself.
    requireAll(names, tree.MODULE_ROOT .. '/teardown')
    local second = teardown.pending()

    expect.equal(duplicates(first), '', 'duplicate hooks after the first pass')
    expect.equal(duplicates(second), '', 'duplicate hooks after the second pass')
    expect.equal(table.concat(second, ','), table.concat(first, ','), 'the hooks registered')
    expect.truthy(#first > 0, 'some module should register a teardown hook')
  end)

  restore(held)
  if not ok then
    error(raised, 0)
  end
end)

-- A module body is run again under an environment that records what it assigns
-- rather than under `_G`, because by the time this case runs every module has
-- already been required once and a global one of them set is already in `_G`.
-- Comparing `_G` before and against after would therefore pass on exactly the
-- defect it is looking for.
--
-- `setfenv` is Lua 5.1's, which is LuaJIT's, so this needs nothing exotic. The
-- `require` calls inside a body resolve normally, so a module still gets the
-- dependencies it expects; only its own assignments are diverted.
spec('no module writes a global', function()
  local names = moduleNames()
  local held = snapshot(names)
  -- A registry of its own, so that the bodies run below register their hooks
  -- somewhere the rest of the suite is not looking at.
  local heldTeardown = package.loaded['@mullion/teardown']
  package.loaded['@mullion/teardown'] = nil
  require '@mullion/teardown'

  local written = {}
  local environment = setmetatable({}, {
    __index = _G,
    __newindex = function(_, key)
      written[#written + 1] = tostring(key)
    end,
  })

  local ok, raised = pcall(function()
    for _, path in ipairs(tree.modules()) do
      local source = lovr.filesystem.read(path)
      if not source then
        error(path .. ' could not be read from the mount')
      end
      local chunk = loadstring(source, '@' .. path)
      if not chunk then
        error(path .. ' did not compile')
      end
      setfenv(chunk, environment)
      chunk()
    end
  end)

  package.loaded['@mullion/teardown'] = heldTeardown
  restore(held)
  if not ok then
    error(raised, 0)
  end

  table.sort(written)
  expect.equal(table.concat(written, ', '), '', 'globals the module bodies wrote')
end)

-- Requiring twice without dropping `package.loaded` is the other half of the
-- rule: a configuration that requires a module a second time gets the module it
-- already had, and not a second copy with a state of its own.
spec('requiring a module twice returns the same table', function()
  for _, name in ipairs(moduleNames()) do
    expect.equal(require(name), require(name), 'two requires of ' .. name)
  end
end)

return spec
