-- The standard library's own file tree, read from the mount.
--
-- `coverage_spec` and `reload_spec` both use the tree. The first lists every
-- module that exists, and the second requires every module. Both read the tree
-- from the mount: a hand-written list would miss a module added under a new
-- subdirectory, and that omission is the defect the two specs catch.
--
-- `lovr.filesystem` is the mount the session resolves `require` through. A
-- module the tree does not list is a module a session cannot load either.
--
-- The runner collects `*_spec.lua` files. `tree.lua` is not one, and it runs
-- no cases of its own.

local tree = {}

-- `walk` is declared above the public API and defined below it. The
-- declaration binds the later definition to a local, and the public API
-- comes first in the file.
local walk

-- Where the standard library and its specs are, as paths in the virtual
-- filesystem. The two trees have explicit mount points. Their paths start
-- with the same `@` roots that `require` resolves.
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
-- `@mullion/persist/init.lua`.
function tree.modules()
  return tree.files(tree.MODULE_ROOT)
end

-- Every spec file, as paths such as `@spec/mullion/persist/file_spec.lua`. The
-- suite's own specs are under `@spec/` directly and are included.
--
-- Files that are not specs, such as `tree.lua`, are left
-- out. The specs are the files that hold cases.
function tree.specs()
  local specs = {}
  for _, path in ipairs(tree.files(tree.SPEC_ROOT)) do
    if path:sub(-#'_spec.lua') == '_spec.lua' then
      specs[#specs + 1] = path
    end
  end
  return specs
end

-- The module name that `require` uses for a path. `@mullion/persist/init.lua`
-- is `@mullion/persist`, and `@mullion/pose.lua` is `@mullion/pose`.
function tree.moduleName(path)
  return path:gsub('%.lua$', ''):gsub('/init$', '')
end

-- Appends every `.lua` file under `directory` to `found`, descending into
-- every subdirectory.
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
