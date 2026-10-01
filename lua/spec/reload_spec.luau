-- Every module is safe to require twice.
--
-- A source reload re-runs every module body outside the runtime's own (docs/dev/lua-api.md#reload), so the
-- check runs every module body again to catch one that fails or leaks a global on a second run.
--
-- This case does not reach the module tables the rest of the suite holds.
-- It restores `package.loaded` before it returns.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local tree = require '@spec/tree'

local spec = suite.new 'spec.reload'

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

-- Drops the `package.loaded` entry for every named module, then requires them
-- all. A dropped module runs its body again.
local function requireAll(names)
  for _, name in ipairs(names) do
    package.loaded[name] = nil
  end
  for _, name in ipairs(names) do
    require(name)
  end
end

spec('requiring every module a second time runs every body again', function()
  local names = moduleNames()
  local held = snapshot(names)

  local ok, raised = pcall(function()
    requireAll(names)
    local first = snapshot(names)
    requireAll(names)

    for _, name in ipairs(names) do
      expect.truthy(package.loaded[name] ~= nil, name .. ' loaded on the second pass')
      expect.falsy(package.loaded[name] == first[name], name .. ' ran its body again')
    end
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
-- `setfenv` is Lua 5.1's, and Luau keeps it. Requires inside a body
-- resolve through `_G`, so a module still gets the dependencies it expects;
-- a body's own assignments are diverted.
spec('no module writes a global', function()
  local names = moduleNames()
  local held = snapshot(names)

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
