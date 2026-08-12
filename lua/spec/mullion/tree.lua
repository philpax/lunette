-- The standard library's own file tree, read from the mount.
--
-- Two specs ask the same question of it — `coverage_spec` wants every module
-- that exists, and `reload_spec` wants to require every one of them — and both
-- have to read the tree rather than a list written by hand. A list written by
-- hand is a list that a module added under a new subdirectory is missing from,
-- which is exactly the defect these two specs exist to catch.
--
-- `lovr.filesystem` is the mount the session resolves `require` through, so a
-- module this cannot see is a module a session cannot load either.
--
-- Not a spec file: the runner collects `*_spec.lua` and this is not one, so it
-- runs no cases of its own.

local tree = {}

-- Declared here and defined below the public API, so the file reads
-- surface-first.
local walk

-- Where the standard library and its specs are, as paths in the virtual
-- filesystem. The two trees have explicit mount points, so their paths carry
-- the same `@` roots that `require` uses.
tree.MODULE_ROOT = '@mullion'
tree.SPEC_ROOT = '@spec'

-- Every `.lua` file under `root`, as paths including it, in sorted order.
function tree.files(root)
  local found = {}
  walk(root, found)
  table.sort(found)
  return found
end

-- Every module of the standard library, as paths such as
-- `mullion/panel/init.lua`.
function tree.modules()
  return tree.files(tree.MODULE_ROOT)
end

-- Every spec file, as paths such as `spec/mullion/panel/panel_spec.lua`. The
-- suite's own specs are under `spec/` directly and are included.
--
-- Files that are not specs — this one, the panel fixture — are left out, since
-- a caller asking for the specs means the files that hold cases.
function tree.specs()
  local specs = {}
  for _, path in ipairs(tree.files(tree.SPEC_ROOT)) do
    if path:sub(-#'_spec.lua') == '_spec.lua' then
      specs[#specs + 1] = path
    end
  end
  return specs
end

-- The module name a path is required by: `@mullion/panel/init.lua` is
-- `@mullion/panel`, and `@mullion/signal.lua` is `@mullion/signal`.
function tree.moduleName(path)
  return path:gsub('%.lua$', ''):gsub('/init$', '')
end

-- Appends every `.lua` file under `directory` to `found`, descending into every
-- subdirectory. Recursive rather than one level deep, because a module added
-- under a new subdirectory is the case a shallow list misses.
function walk(directory, found)
  for _, item in ipairs(lovr.filesystem.getDirectoryItems(directory)) do
    local child = directory .. '/' .. item
    if lovr.filesystem.isDirectory(child) then
      walk(child, found)
    elseif item:sub(-#'.lua') == '.lua' then
      found[#found + 1] = child
    end
  end
end

return tree
