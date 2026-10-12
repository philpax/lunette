local testing = require '@testing'
local fixture = require './support/source-controls'
local vrUi = require '@testing/vr-ui'
local expect = testing.expect
local test = testing.suite()
local PANEL = 'desktop/backdrop/controls'

test('vr_backdrop_source_controls', function()
  local env = fixture.boot { settings = { sourceMode = 'attention' } }
  local process = env.native.newProcess(41)
  fixture.window(env, 41, process)
  for index = 42, 60 do
    env.native.newProcess(index)
  end
  env.running:step(0.75)
  env.running:step(0)
  fixture.open(env)
  expect.truthy(env.choice.frozen, 'the menu action opens the panel and freezes attention')
  local description = vrUi.describe(env.ui, PANEL)
  expect.truthy(description.visible, 'Backdrop is reachable through the controller menu')
  local _, list = env.running:discover(env.ui, PANEL, 'applications')
  expect.truthy(
    string.find(list.items[1].label, 'org.fixture.Player', 1, true),
    'application ids label associated windows'
  )
  expect.truthy(
    string.find(list.items[1].label, '#41', 1, true),
    'the process id is only a distinguishing label suffix'
  )
  env.running:clickControl(env.ui, PANEL, 'pin-now')
  expect.equal(env.choice.mode, 'application', 'pin-now leaves attention mode')
  expect.equal(env.choice.pinned, process, 'pin-now retains the exact live process handle')
  fixture.choice(env, 'source-mode', 'system')
  expect.equal(env.choice:source().kind, 'system', 'a controller explicitly selects the mix')
  env.running:clickControl(env.ui, PANEL, 'applications', 'right', list.items[1].id)
  expect.equal(env.choice.pinned, process, 'an application row selects its live process handle')
  expect.equal(env.choice.mode, 'application', 'an application row enters pinned mode')
  local staleGeometry, stale = env.running:discover(env.ui, PANEL, 'applications', list.items[1].id)
  env.running:aim(staleGeometry, stale.bounds.x + 10, stale.bounds.y + 10)
  env.running:step(0)
  env.running:button('right', 'trigger', true)
  env.running:step(0)
  process.dead = true
  env.running:button('right', 'trigger', false)
  env.running:step(0)
  expect.equal(env.choice.pinned, process, 'a stale list invocation does not select a replacement row')
  expect.equal(env.choice:source().kind, 'process', 'a dead selected process does not fall back to the mix')
  process.dead = false
  env.running:step(0)
  fixture.choice(env, 'source-mode', 'application')
  fixture.choice(env, 'reactive', 'off')
  expect.equal(env.choice:source(), nil, 'a controller disables audio reactivity')
  fixture.choice(env, 'reactive', 'on')
  fixture.choice(env, 'enabled', 'off')
  expect.equal(env.enabled(), false, 'a controller disables the backdrop')
  fixture.choice(env, 'enabled', 'on')
  fixture.choice(env, 'response', '0.25')
  fixture.choice(env, 'motion', '0.75')
  expect.equal(env.choice.response, 0.25, 'the response preset is bounded and controller accessible')
  expect.equal(env.choice.motion, 0.75, 'the motion preset is bounded and controller accessible')
  local geometry, applications = env.running:discover(env.ui, PANEL, 'applications')
  env.running:aim(geometry, applications.bounds.x + 40, applications.bounds.y + 40)
  env.running:step(0)
  env.running:axis('right', 0, -1)
  env.running:step(0.5)
  env.running:axis('right', 0, 0)
  local _, scrolled = env.running:discover(env.ui, PANEL, 'applications')
  expect.truthy(
    scrolled.items[1].id ~= applications.items[1].id,
    'controller stick scrolling moves earlier application rows out of view'
  )
  env.running:clickControl(env.ui, PANEL, 'dismiss')
  expect.equal(env.choice.frozen, false, 'closing unfreezes attention')
  expect.equal(vrUi.describe(env.ui, PANEL).visible, false, 'closing hides the shared panel')
  expect.equal(env.running:keyboardCount(), 0, 'the controls never request a physical or virtual keyboard')
  env.running:close()
end)

test('application row labels use nonempty titles, then application ids, then explicit process labels', function()
  local controls = require '../controls'
  local selection = require '../selection'
  local choice = selection.new()
  local fields = {
    { title = 'Document', appId = 'org.fixture.Editor', label = 'Document (org.fixture.Editor)' },
    { title = 'org.fixture.Editor', appId = 'org.fixture.Editor', label = 'org.fixture.Editor' },
    { title = 'Document', appId = '', label = 'Document' },
    { title = 'Document', label = 'Document' },
    { title = '', appId = 'org.fixture.Editor', label = 'org.fixture.Editor' },
    { appId = 'org.fixture.Editor', label = 'org.fixture.Editor' },
    { title = '', appId = '' },
    { appId = '' },
    { title = '' },
    {},
  }
  for index, values in fields do
    local process = { id = 100 + index, dead = false }
    local window = { process = process, dead = false, title = values.title, appId = values.appId }
    local expected = values.label or 'Process ' .. tostring(process.id)
    local row = controls.rows(choice, { process }, { window })[1]
    expect.equal(
      row.label,
      expected .. ' · #' .. process.id .. ' · audio provider unavailable',
      'label case ' .. index
    )
    expect.equal(row.process, process, 'the label never replaces process identity')
  end
  local process = { id = 200, dead = false }
  choice.processStatuses = { { process = process, label = '' } }
  expect.equal(
    controls.rows(choice, { process }, {})[1].label,
    'Process 200 · #200 · audio provider unavailable',
    'an empty provider label also uses the explicit process fallback'
  )
  choice.processStatuses = {}
  expect.equal(
    controls.rows(choice, { process }, {})[1].label,
    'Process 200 · #200 · audio provider unavailable',
    'a process without windows or provider labels is explicitly named'
  )
end)

return test
