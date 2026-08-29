-- Every module of the standard library has a spec or a recorded exemption.
--
-- A thin module may lack a spec; the absence must be deliberate, not
-- accidental. The table below names every module and what covers it. A
-- module added without an entry fails the first check below.
--
-- The tree is read from the mount, not listed by hand, so a module added
-- under a new subdirectory appears. The `Makefile`'s install rule walks
-- the tree for the same reason: a file the list misses resolves in
-- development and is absent from an installed session.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local tree = require '@spec/mullion/tree'

local spec = suite.new 'mullion.coverage'

-- The specs covering the standard library are under the `@spec` mount.
local MULLION_SPECS = '@spec/mullion'

-- What covers each module: a spec path under `spec/mullion`, an array of
-- them for a module whose specs split along a seam, or `false` with the
-- reason it is exempt.
--
-- Keyed by the path under `mullion/`, matching the tree's module paths.
local COVERAGE = {
  -- The root module holds no state, registers nothing, and returns an empty
  -- table. There is no behaviour for a spec to assert beyond requiring it,
  -- and `crates/lunette/tests/standard_library.rs` requires it from a real
  -- session to check the mount.
  ['init.lua'] = false,
  ['adopt.lua'] = 'adopt_spec.lua',
  ['error/init.lua'] = 'error/handler_spec.lua',
  ['error/panel.lua'] = 'error/panel_spec.lua',
  ['interaction/init.lua'] = 'interaction_spec.lua',
  -- Declares the pointer protocol's vocabulary and returns an empty table;
  -- there is no behaviour for a spec to assert. The Luau check covers it.
  ['interaction/types.lua'] = false,
  -- The carrying half, exercised through the pointer that installs it.
  ['interaction/grab.lua'] = 'interaction_spec.lua',
  ['keyboard/init.lua'] = 'keyboard_spec.lua',
  -- Pure geometry and legends, exercised through the keyboard that calls it.
  ['keyboard/layout.lua'] = 'keyboard_spec.lua',
  -- Drawing, which the spec's recording pass exercises through `draw`.
  ['keyboard/draw.lua'] = 'keyboard_spec.lua',
  ['keycodes.lua'] = 'keycodes_spec.lua',
  ['laser.lua'] = 'laser_spec.lua',
  ['layout/arc.lua'] = 'layout/arc_spec.lua',
  ['pacing.lua'] = 'pacing_spec.lua',
  ['panel/init.lua'] = 'panel/panel_spec.lua',
  -- The claim and the layer it is granted, exercised through a panel's update.
  ['panel/layer.lua'] = 'panel/panel_spec.lua',
  ['panel/raycast.lua'] = 'panel/raycast_spec.lua',
  ['persist/format.lua'] = 'persist/format_spec.lua',
  -- Split along the module's own seam: one half is arrangements and panels, the
  -- other is the file on disk.
  ['persist/init.lua'] = { 'persist/arrangement_spec.lua', 'persist/file_spec.lua' },
  ['pose.lua'] = 'pose_spec.lua',
  ['rules.lua'] = 'rules_spec.lua',
  ['scale.lua'] = 'scale_spec.lua',
  ['signal.lua'] = 'signal_spec.lua',
  ['tag.lua'] = 'tag_spec.lua',
  ['teardown.lua'] = 'teardown_spec.lua',
}

-- The specs that cover the suite itself. The check below does not require a
-- module claim for them.
local ABOUT_THE_SUITE = {
  ['@spec/mullion/coverage_spec.lua'] = true,
  ['@spec/mullion/reload_spec.lua'] = true,
  ['@spec/runner_spec.lua'] = true,
}

-- The path under `mullion/` that `path` names.
local function relative(path)
  return (path:gsub('^' .. tree.MODULE_ROOT .. '/', ''))
end

-- The spec paths a coverage entry names, as an array. The checks below read
-- one-spec and two-spec entries the same way.
local function covering(entry)
  if not entry then
    return {}
  end
  if type(entry) == 'string' then
    return { entry }
  end
  return entry
end

spec('every module is named in the coverage table', function()
  local missing = {}
  for _, path in ipairs(tree.modules()) do
    if COVERAGE[relative(path)] == nil then
      missing[#missing + 1] = path
    end
  end

  expect.equal(table.concat(missing, ', '), '', 'modules with no entry in the coverage table')
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
  for module, entry in pairs(COVERAGE) do
    for _, path in ipairs(covering(entry)) do
      if not present[MULLION_SPECS .. '/' .. path] then
        missing[#missing + 1] = module .. ' -> ' .. path
      end
    end
  end
  table.sort(missing)

  expect.equal(table.concat(missing, ', '), '', 'entries naming a spec that is not there')
end)

spec('every spec covers a module or is about the suite', function()
  local claimed = {}
  for _, entry in pairs(COVERAGE) do
    for _, path in ipairs(covering(entry)) do
      claimed[MULLION_SPECS .. '/' .. path] = true
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
