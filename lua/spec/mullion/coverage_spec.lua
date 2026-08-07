-- Every module of the standard library has a spec, or is exempt on purpose.
--
-- A module with no spec is not necessarily a defect — some are thin — but the
-- absence has to be deliberate rather than accidental. This is what makes it
-- deliberate: the table below names every module and what covers it, and a
-- module added without an entry fails here rather than going unnoticed.
--
-- The tree is read from the mount rather than listed by hand, so a module added
-- under a new subdirectory is seen. That is the same defect the `Makefile`'s
-- install rule guards against by walking the tree: a file the list misses
-- resolves in development and is absent from an installed session.

local expect = require 'spec.expect'
local suite = require 'spec.suite'

local tree = require 'spec.mullion.tree'

local spec = suite.new 'mullion.coverage'

-- Where the specs covering the standard library are, under `spec.SPEC_ROOT`.
local MULLION_SPECS = 'spec/mullion'

-- What covers each module, as a spec path under `spec/mullion`, or `false` with
-- the reason it is exempt.
--
-- Keyed by the path under `mullion/`, so it reads as the tree does.
local COVERAGE = {
  -- The root module holds no state, registers nothing, and returns an empty
  -- table. There is nothing to assert that requiring it does not already
  -- assert, and `crates/lunette/tests/standard_library.rs` requires it from a
  -- real session to check the mount.
  ['init.lua'] = false,
  ['error.lua'] = 'error_spec.lua',
  ['interaction.lua'] = 'interaction_spec.lua',
  ['keyboard.lua'] = 'keyboard_spec.lua',
  ['keycodes.lua'] = 'keycodes_spec.lua',
  ['laser.lua'] = 'laser_spec.lua',
  ['layout/arc.lua'] = 'layout/arc_spec.lua',
  ['panel/init.lua'] = 'panel/panel_spec.lua',
  ['panel/raycast.lua'] = 'panel/raycast_spec.lua',
  ['persist/format.lua'] = 'persist/format_spec.lua',
  ['persist/init.lua'] = 'persist/arrangement_spec.lua',
  ['pose.lua'] = 'pose_spec.lua',
  ['rules.lua'] = 'rules_spec.lua',
  ['signal.lua'] = 'signal_spec.lua',
  ['tag.lua'] = 'tag_spec.lua',
  ['teardown.lua'] = 'teardown_spec.lua',
}

-- The specs that cover the suite itself rather than a module, so the check
-- below does not ask which module they are for.
local ABOUT_THE_SUITE = {
  ['spec/mullion/coverage_spec.lua'] = true,
  ['spec/mullion/reload_spec.lua'] = true,
  ['spec/runner_spec.lua'] = true,
}

-- The path under `mullion/` that `path` names.
local function relative(path)
  return (path:gsub('^' .. tree.MODULE_ROOT .. '/', ''))
end

spec('every module is named in the coverage table', function()
  local missing = {}
  for _, path in ipairs(tree.modules()) do
    if COVERAGE[relative(path)] == nil then
      missing[#missing + 1] = path
    end
  end

  expect.equal(
    table.concat(missing, ', '),
    '',
    'modules with no entry in the coverage table'
  )
end)

spec('every module the coverage table names exists', function()
  local present = {}
  for _, path in ipairs(tree.modules()) do
    present[relative(path)] = true
  end

  local stale = {}
  for module in pairs(COVERAGE) do
    if not present[module] then
      stale[#stale + 1] = module
    end
  end
  table.sort(stale)

  expect.equal(table.concat(stale, ', '), '', 'entries naming a module that is gone')
end)

spec('every spec the coverage table names exists', function()
  local present = {}
  for _, path in ipairs(tree.specs()) do
    present[path] = true
  end

  local missing = {}
  for module, covering in pairs(COVERAGE) do
    if covering and not present[MULLION_SPECS .. '/' .. covering] then
      missing[#missing + 1] = module .. ' -> ' .. covering
    end
  end
  table.sort(missing)

  expect.equal(table.concat(missing, ', '), '', 'entries naming a spec that is not there')
end)

spec('every spec covers a module or is about the suite', function()
  local claimed = {}
  for _, covering in pairs(COVERAGE) do
    if covering then
      claimed[MULLION_SPECS .. '/' .. covering] = true
    end
  end

  local orphans = {}
  for _, path in ipairs(tree.specs()) do
    if not claimed[path] and not ABOUT_THE_SUITE[path] then
      orphans[#orphans + 1] = path
    end
  end

  expect.equal(table.concat(orphans, ', '), '', 'specs no module claims')
end)

return spec
