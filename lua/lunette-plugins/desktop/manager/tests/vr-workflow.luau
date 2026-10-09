local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local fixture = require './support/vr-manager'
local suite = testing.suite()
local test = fixture.testCases(suite)

local function control(env, id)
  for _, description in env:description().controls do
    if description.id == id then
      return description
    end
  end
  return nil
end

local function editingEntry()
  local current
  local definition = plugin.consumer({
    name = 'vr-workflow-editor',
    schema = schema.object { title = schema.default(schema.string()) 'initial' },
    init = function(_context, settings)
      current = settings
    end,
  }).definition
  return { id = 'vr-workflow-editor', definition = definition }, function()
    return current
  end
end

test('manager complete VR workflow discovers shared widgets and closes field routes', function()
  local env = fixture.boot()
  env:open()
  local initial = env:description()
  expect.truthy(initial.visible, 'Plugins opens the shared panel')
  local controls = {}
  for _, control in initial.controls do
    controls[control.id] = control
  end
  local _, close = env.controls:discover(env.services.ui, 'desktop/manager/titlebar', 'close')
  controls.close = close
  for _, id in
    {
      'graph',
      'zoom-in',
      'zoom-out',
      'fit',
      'search',
      'clear-filter',
      'clear-selection',
      'inspect',
      'catalog',
      'close',
    }
  do
    expect.truthy(controls[id], 'public geometry describes ' .. id)
  end
  env:click 'zoom-in'
  env:click 'zoom-out'
  env:click 'fit'
  local selected = assert(env:entry 'desktop/manager')
  env:click('graph', 'node/' .. selected.instanceId)
  env:click 'search'
  expect.truthy(env.services.display:isVisible(), 'Search opens the existing shared keyboard')
  expect.truthy(env.services.focus:focused(), 'a text field owns the route')
  expect.equal(env:keyboardCount(), 1, 'Search creates one actual keyboard')
  env:key 'Text'
  env:key 'Hide'
  expect.equal(env.services.focus:focused(), nil, 'keyboard user-hide releases only the field route')
  env:click 'search'
  expect.equal(env:keyboardCount(), 1, 'resuming Search reuses that keyboard')
  env:click 'clear-filter'
  env:click 'clear-selection'
  env:click 'close'
  expect.falsy(env:description().visible, 'Close hides the manager')
  expect.equal(env.services.focus:focused(), nil, 'Close blurs the field')
  expect.falsy(env.services.display:isVisible(), 'Close ends automatic keyboard visibility')
  env:open()
  expect.truthy(env:description().visible, 'Plugins reopens the same manager')
  expect.equal(env:description().generation, initial.generation, 'ordinary reopening retains the panel generation')
  env:close()
end)

test('Close cancels an edited field and reopening restores no stale route', function()
  local entry, current = editingEntry()
  local env = fixture.boot { entry }
  env:open()
  local initial = env:description()
  env:click('graph', 'node/' .. assert(env:entry(entry.id)).instanceId)
  env:click 'configure'
  env:click('rows', 'row/s:title')
  env:click 'edit-field'
  env:key 'All'
  env:key 'Text'
  expect.truthy(env.services.focus:focused(), 'the edited field owns the keyboard route')
  expect.truthy(env.services.display:isVisible(), 'the editor displays the shared keyboard')
  expect.equal(current().title, 'initial', 'unconfirmed text does not change the activation')
  env:click 'close'
  expect.falsy(env:description().visible, 'Close hides the manager during editing')
  expect.equal(env.services.focus:focused(), nil, 'Close releases the edited field route')
  expect.falsy(env.services.display:isVisible(), 'Close ends automatic keyboard visibility')
  env:open()
  expect.truthy(env:description().visible, 'wrist Plugins reopens the manager')
  expect.equal(env:description().generation, initial.generation, 'reopening retains the shared panel generation')
  expect.equal(control(env, 'edit-field'), nil, 'reopening has no stale edited field')
  expect.equal(env.services.focus:focused(), nil, 'reopening does not reclaim the old field route')
  expect.falsy(env.services.display:isVisible(), 'reopening does not restore automatic keyboard visibility')
  env:click('rows', 'row/s:title')
  env:click 'edit-field'
  env:click 'confirm'
  env:click 'apply'
  expect.equal(current().title, 'initial', 'Close cancels unconfirmed text instead of applying it on the next edit')
  env:close()
end)

return suite
