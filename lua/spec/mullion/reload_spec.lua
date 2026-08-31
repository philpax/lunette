-- Every module is safe to require twice.
--
-- A soft reload discards the Lua state and runs every module body again
-- (docs/dev/lua-api.md#reload). CONTRIBUTING.md makes a module that leaks a
-- timer, a signal connection, or a teardown hook across a reload a defect.
-- The check walks the tree, requires every module twice, and counts what
-- accumulated. The suite catches the leak; review does not have to notice
-- it.
--
-- The registry is the module-level state of `mullion.teardown`. The second
-- pass keeps that module and re-runs every other body, so both passes
-- use the same registry, as a reload does. `teardown.register` replaces a
-- hook under its name; appending would leave two hooks under one name.
--
-- This case does not reach the module tables the rest of the suite holds.
-- The snapshot tables the case builds are its own, and it restores
-- `package.loaded` before it returns.

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

-- What `package.loaded` holds for each of `names`.
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

-- Drops the `package.loaded` entry for every named module except the one
-- `keep` names, then requires them all. A dropped module runs its body again.
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

-- The names that appear more than once in `pending`, joined by ', '.
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
    -- The first pass builds a registry of its own. The counts below describe
    -- this case, not the registrations the rest of the suite holds.
    requireAll(names)
    local teardown = require '@mullion/teardown'
    local first = teardown.pending()

    -- Named as the tree names it. The name must match the module name the
    -- tree produces; any other form matches no module, and `requireAll` drops
    -- the teardown module and runs its body again. The two passes then
    -- register into different registries, and the local `teardown` table
    -- still holds the first, so the assertions compare a registry against
    -- itself.
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

-- A module body runs under an environment that records what it assigns.
-- The bodies do not run under `_G`. By the time this case runs, every module
-- has been required once already, and a global one of them set is already in
-- `_G`. A comparison of `_G` before and after the runs would pass even when
-- a body writes a global.
--
-- `setfenv` is Lua 5.1's, and LuaJIT keeps it. Requires inside a body
-- resolve through `_G`, so a module still gets the dependencies it expects;
-- a body's own assignments are diverted.
spec('no module writes a global', function()
  local names = moduleNames()
  local held = snapshot(names)
  -- The entry is dropped so the require that follows re-runs the module
  -- body. The body builds a fresh registry, separate from the registry the
  -- rest of the suite holds.
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

-- The other half of the rule leaves `package.loaded` in place: a
-- configuration that requires a module a second time gets the module it
-- already had, not a second copy with a state of its own.
spec('requiring a module twice returns the same table', function()
  for _, name in ipairs(moduleNames()) do
    expect.equal(require(name), require(name), 'two requires of ' .. name)
  end
end)

return spec
