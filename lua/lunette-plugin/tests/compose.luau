-- Covers composition: patches that merge, replace, disable, and insert entries, the configure patch, the
-- malformed patches each named by id, a factory called once per start, and a rejected configuration failing
-- only its own plugin.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'

local test = testing.suite()

local hud = plugin.define { name = 'hud', init = function() end }
local labelled = plugin.define {
  name = 'labelled',
  init = function(_context, config)
    plugin.options {
      name = 'labelled',
      defaults = { label = 'none', style = { size = 1, color = { 0, 0, 1 } } },
      config = config,
    }
  end,
}

local function ids(entries)
  local result = {}
  for index, entry in ipairs(entries) do
    result[index] = entry.id
  end
  return table.concat(result, ' ')
end

local ENTRIES = {
  { id = 'first', definition = hud },
  { id = 'labelled', definition = labelled, config = { style = { size = 1, color = { 0, 0, 1 } } } },
  { id = 'last', definition = hud },
}

test('a record merges key by key, anything else replaces, and composing leaves its inputs as they were', function()
  local merged = plugin.compose(ENTRIES, { { id = 'labelled', config = { style = { size = 2 } } } })
  expect.equal(merged[2].config.style.size, 2, 'the merged key')
  expect.equal(merged[2].config.style.color[3], 1, 'the key the patch left out')
  local replaced = plugin.compose(ENTRIES, { { id = 'labelled', config = { style = { color = { 1 } } } } })
  expect.equal(#replaced[2].config.style.color, 1, 'a list replaces')
  expect.equal(ENTRIES[2].config.style.size, 1, 'the input entry')
  expect.truthy(table.isfrozen(merged) and table.isfrozen(merged[2].config.style), 'the composition is frozen')
end)

test('disabling removes the entry and nothing else moves', function()
  expect.equal(ids(plugin.compose(ENTRIES, { { id = 'labelled', disabled = true } })), 'first last')
end)

test('an insert goes at the end, or before or after the entry it names', function()
  local function inserted(patches)
    return ids(plugin.compose(ENTRIES, patches))
  end
  expect.equal(inserted { { insert = { id = 'extra', definition = hud } } }, 'first labelled last extra', 'at the end')
  expect.equal(
    inserted { { insert = { id = 'extra', definition = hud }, before = 'last' } },
    'first labelled extra last',
    'before'
  )
  expect.equal(
    inserted {
      { insert = { id = 'extra', definition = hud }, after = 'first' },
      { insert = { id = 'extra-2', definition = hud }, after = 'extra' },
    },
    'first extra extra-2 labelled last',
    'after an entry inserted by an earlier patch'
  )
end)

test("a configure patch is the plain patch for its definition's name", function()
  local patch = plugin.configure(labelled) { label = 'hud' }
  expect.equal(patch.id, 'labelled', 'the id')
  expect.equal(plugin.compose(ENTRIES, { patch })[2].config.label, 'hud', 'the configuration it carries')
  local factory = function()
    return labelled
  end
  expect.equal(plugin.configure(factory)({}).id, 'labelled', "a factory's definition names the patch")
  expect.raises(function()
    plugin.configure('labelled' :: any)
  end, 'configure takes a plugin definition or a factory of one, not a string')
end)

test('a malformed composition raises before anything is defined, naming the id', function()
  for _, case in ipairs {
    { patches = { { id = 'nope', disabled = true } }, message = 'a patch names nope, which is not an entry' },
    {
      patches = { { id = 'last', disabled = true }, { id = 'last', config = {} } },
      message = 'two patches name last',
    },
    { patches = { { id = 'last', disable = true } }, message = 'patch 1: unknown field disable' },
    {
      patches = { { id = 'last', disabled = true, config = {} } },
      message = 'the patch for last disables the entry and also changes it',
    },
  } do
    expect.raises(function()
      plugin.compose(ENTRIES, case.patches :: any)
    end, case.message)
  end
end)

test('a factory is called once for each start and never by compose', function()
  local made = 0
  local entries = {
    {
      id = 'counted',
      factory = function()
        made += 1
        return hud
      end,
    },
  }
  plugin.compose(entries)
  expect.equal(made, 0, 'compose calls no factory')
  local first, second = plugin.start(entries), plugin.start(entries)
  expect.equal(made, 2, 'each start calls it')
  expect.equal(first.instances.counted:state(), 'active', 'the instance of its definition')
  first.runtime:close()
  second.runtime:close()
end)

test('a configuration a plugin does not take fails that plugin alone, naming the option', function()
  local running = plugin.start(plugin.compose(ENTRIES, { { id = 'labelled', config = { colour = 'red' } } }))
  expect.equal(running.instances.labelled:state(), 'failed', 'the misconfigured plugin')
  expect.truthy(
    tostring(running.instances.labelled:diagnostic()):find('plugin labelled: unknown option colour', 1, true),
    'the diagnostic'
  )
  expect.equal(running.instances.last:state(), 'active', 'the plugin after it')
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the failure is reported')
  running.runtime:close()
end)

return test
