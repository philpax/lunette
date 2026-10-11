local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local schema = require '@lunette-plugin/schema'

local test = testing.suite()

type CompositionEntry = { read id: string }
type Patches = {
  {
    read insert: { read id: string, read definition: adapter.Definition<{}> },
    read before: string?,
    read after: string?,
  }
}
type LabelledConfig = { label: string?, style: { size: number?, color: { number }? }? }

local hud = adapter.define { name = 'hud', init = function() end }
local labelled = plugin.consumer({
  name = 'labelled',
  schema = schema.object {
    label = schema.default(schema.string()) 'none',
    style = schema.default(schema.object {
      size = schema.default(schema.number())(1),
      color = schema.default(schema.array(schema.number())) { 0, 0, 1 },
    }) { size = 1, color = { 0, 0, 1 } },
  },
  init = function() end,
}).definition

local function ids(entries: { read [number]: CompositionEntry }): string
  local result: { string } = {}
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
  local function inserted(patches: Patches): string
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

test('a configure patch must target the entry it names, and making it calls no factory', function()
  local made = 0
  local function factory(): adapter.Definition<LabelledConfig>
    made += 1
    return labelled
  end
  local patch = plugin.configure('made', factory) { label = 'hud' }
  expect.equal(patch.id, 'made', 'the id')
  expect.equal(made, 0, 'making the patch invokes no factory')
  local entries = { { id = 'made', definition = factory } }
  expect.equal(plugin.compose(entries, { patch })[1].config.label, 'hud', 'the configuration it carries')
  expect.raises(function()
    plugin.compose(ENTRIES, { plugin.configure('labelled', factory) { label = 'hud' } })
  end, 'the patch for labelled targets another definition than the entry has')
end)

test('a malformed composition raises before anything is defined, naming the id', function()
  for _, case in ipairs {
    { patches = { { id = 'nope', disabled = true } }, message = 'a patch names nope, which is not an entry' },
    {
      patches = { { id = 'last', disabled = true }, { id = 'last', config = {} } },
      message = 'two patches name last',
    },
  } do
    expect.raises(function()
      plugin.compose(ENTRIES, case.patches :: any)
    end, case.message)
  end
end)

test('a configuration a plugin does not take fails that plugin alone, naming the option', function()
  local running = testing.start(plugin.compose(ENTRIES, { { id = 'labelled', config = { colour = 'red' } } }))
  expect.equal(running.instances.labelled:state(), 'failed', 'the misconfigured plugin')
  expect.truthy(
    tostring(testing.diagnostic(running.runtime, running.instances.labelled)):find(
      'plugin labelled: option colour is not a declared field',
      1,
      true
    ),
    'the diagnostic'
  )
  expect.equal(running.instances.last:state(), 'active', 'the plugin after it')
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the failure is reported')
end)

return test
