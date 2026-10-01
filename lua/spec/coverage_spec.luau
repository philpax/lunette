-- Every module the specs own has a spec or a recorded exemption.
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

local tree = require '@spec/tree'

local spec = suite.new 'spec.coverage'

-- What covers each module: a spec path under `@spec/`, an array of them for a
-- module whose specs split along a seam, or `false` with the reason it is
-- exempt.
--
-- Keyed by the module's path without its leading `@`, matching the tree's
-- module paths. A module's specs sit under `@spec/` at the module's own path.
local COVERAGE = {
  ['lunette-desktop/persist/format.luau'] = 'lunette-desktop/persist/format_spec.luau',
  -- Split along the module's own seam: one half is arrangements and panels, the
  -- other is the file on disk.
  ['lunette-desktop/persist/init.luau'] = {
    'lunette-desktop/persist/arrangement_spec.luau',
    'lunette-desktop/persist/file_spec.luau',
  },
  -- Capture and restore, exercised through a state's capture and bind.
  ['lunette-desktop/persist/arrangement.luau'] = 'lunette-desktop/persist/arrangement_spec.luau',
  -- Slot holds, exercised through the source a spec builds over them.
  ['lunette-desktop/persist/slots.luau'] = 'lunette-desktop/persist/arrangement_spec.luau',
  ['lunette-contracts/keys.luau'] = 'lunette-contracts/keys_spec.luau',
  ['lunette-contracts/vocabulary.luau'] = 'lunette-contracts/vocabulary_spec.luau',
  ['lunette-plugins/keyboard/rows.luau'] = 'lunette-plugins/keyboard/rows_spec.luau',
  ['lunette-plugins/interaction/picking.luau'] = 'lunette-plugins/interaction/picking_spec.luau',
  ['lunette-plugins/panels/shape.luau'] = 'lunette-plugins/panels/shape_spec.luau',
  ['lunette-plugins/pacing/pacer.luau'] = 'lunette-plugins/pacing/pacer_spec.luau',
  ['lunette-plugins/scale/chooser.luau'] = 'lunette-plugins/scale/chooser_spec.luau',
}

-- The specs that cover the suite itself. The check below does not require a
-- module claim for them.
local ABOUT_THE_SUITE = {
  ['@spec/coverage_spec.luau'] = true,
  ['@spec/reload_spec.luau'] = true,
  ['@spec/runner_spec.luau'] = true,
}

-- The path `path` names, without its leading `@`.
local function relative(path)
  return (path:gsub('^@', ''))
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
      if not present[tree.SPEC_ROOT .. '/' .. path] then
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
      claimed[tree.SPEC_ROOT .. '/' .. path] = true
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
