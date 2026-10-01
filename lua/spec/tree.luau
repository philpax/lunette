-- The file tree the Lua specs own, read from the mount.
--
-- `coverage_spec` and `reload_spec` both use the tree. The first lists every
-- module that exists, and the second requires every module. Both read the tree
-- from the mount: a hand-written list would miss a module added under a new
-- subdirectory, and that omission is the defect the two specs catch.
--
-- `lovr.filesystem` is the mount the session resolves `require` through. A
-- module the tree does not list is a module a session cannot load either.
--
-- The runner collects `*_spec.luau` files. `tree.luau` is not one, and it runs
-- no cases of its own.

local tree = {}

-- `walk` is declared above the public API and defined below it. The
-- declaration binds the later definition to a local, and the public API
-- comes first in the file.
local walk

-- The modules the Lua specs own, as paths in the virtual filesystem. Each is
-- a directory, walked for every `.luau` file under it, or a single file. The
-- paths start with the same `@` roots that `require` resolves.
--
-- The rest of the shipped roots are providers, contracts, and desktop
-- consumers that the Rust integration tests under `crates/lunette/tests/`
-- drive through the plugin runtime. The modules here are the ones with
-- behaviour a spec can reach without a runtime: the desktop's persistence,
-- the shared vocabulary, the keyboard's default rows, the pointer picking
-- arithmetic, a curved panel's geometry, and the frame pacing and output
-- scale rules.
tree.MODULE_ROOTS = {
  '@lunette-desktop/persist',
  '@lunette-contracts/keys.luau',
  '@lunette-contracts/vocabulary.luau',
  '@lunette-plugins/keyboard/rows.luau',
  '@lunette-plugins/interaction/picking.luau',
  '@lunette-plugins/panels/shape.luau',
  '@lunette-plugins/pacing/pacer.luau',
  '@lunette-plugins/scale/chooser.luau',
}
tree.SPEC_ROOT = '@spec'

-- Every `.luau` file under `root`, as paths including it, in sorted order. A
-- root that is a file answers itself.
function tree.files(root)
  if not lovr.filesystem.isDirectory(root) then
    if not lovr.filesystem.isFile(root) then
      error(root .. ' is not in the mount')
    end
    return { root }
  end
  local found = {}
  walk(root, found)
  table.sort(found)
  return found
end

-- Every module the specs own, as paths such as
-- `@lunette-desktop/persist/init.luau`, in sorted order.
function tree.modules()
  local found = {}
  for _, root in ipairs(tree.MODULE_ROOTS) do
    for _, path in ipairs(tree.files(root)) do
      found[#found + 1] = path
    end
  end
  table.sort(found)
  return found
end

-- Every spec file, as paths such as
-- `@spec/lunette-desktop/persist/file_spec.luau`. The suite's own specs are
-- under `@spec/` directly and are included.
--
-- Files that are not specs, such as `tree.luau`, are left
-- out. The specs are the files that hold cases.
function tree.specs()
  local specs = {}
  for _, path in ipairs(tree.files(tree.SPEC_ROOT)) do
    if path:sub(-#'_spec.luau') == '_spec.luau' then
      specs[#specs + 1] = path
    end
  end
  return specs
end

-- The module name that `require` uses for a path.
-- `@lunette-desktop/persist/init.luau` is `@lunette-desktop/persist`, and
-- `@lunette-plugins/scale/chooser.luau` is `@lunette-plugins/scale/chooser`.
function tree.moduleName(path)
  return path:gsub('%.luau$', ''):gsub('/init$', '')
end

-- Appends every `.luau` file under `directory` to `found`, descending into
-- every subdirectory.
function walk(directory, found)
  for _, item in ipairs(lovr.filesystem.getDirectoryItems(directory)) do
    local child = directory .. '/' .. item
    if lovr.filesystem.isDirectory(child) then
      walk(child, found)
    elseif item:sub(-#'.luau') == '.luau' then
      found[#found + 1] = child
    end
  end
end

return tree
