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

test('fresh equal process handles preserve a VR row press and stable bounded tokens across frames', function()
  local lunette = require '@lunette'
  local env = fixture.boot { freshProcesses = true }
  local process = env.native.newProcess(71)
  fixture.window(env, 71, process)
  local first, second = lunette.processes()[1], lunette.processes()[1]
  expect.equal(rawequal(first, second), false, 'each enumeration returns a distinct handle wrapper')
  expect.truthy(first == second and second == process, 'fresh handles compare by their canonical process')
  first, second = nil, nil
  fixture.open(env)
  local geometry, row = env.running:discover(env.ui, PANEL, 'applications')
  local token = row.items[1].id
  expect.truthy(
    string.find(row.items[1].label, 'org.fixture.Player', 1, true),
    'window associations survive fresh process wrappers'
  )
  env.running:aim(geometry, row.items[1].bounds.x + 10, row.items[1].bounds.y + 10)
  env.running:step(0)
  env.running:button('right', 'trigger', true)
  env.running:step(0)
  local stable = true
  for _ = 1, 300 do
    env.running:step(0)
    local _, current = env.running:discover(env.ui, PANEL, 'applications')
    stable = stable and current.items[1].id == token
  end
  env.running:button('right', 'trigger', false)
  env.running:step(0)
  expect.equal(env.choice.mode, 'application', 'releasing a row after fresh-handle frames still pins it')
  expect.equal(env.choice.pinned, process, 'the row pins the same live process identity')
  expect.truthy(stable, 'unchanged rows keep their token through every frame')
  expect.truthy(env.processBoundary.retained() <= 2, 'retained wrappers are bounded by current rows and the pin')
  env.running:close()
end)

test('absent process rows release handles and never reuse a stale VR row token', function()
  local env = fixture.boot { freshProcesses = true }
  local process = env.native.newProcess(81)
  fixture.open(env)
  local geometry, list = env.running:discover(env.ui, PANEL, 'applications')
  local token = list.items[1].id
  env.running:aim(geometry, list.items[1].bounds.x + 10, list.items[1].bounds.y + 10)
  env.running:step(0)
  env.running:button('right', 'trigger', true)
  env.running:step(0)
  table.clear(env.native.events.processes)
  env.running:button('right', 'trigger', false)
  env.running:step(0)
  expect.equal(env.choice.pinned, nil, 'a process absent at invocation cannot be pinned even if its handle is live')
  expect.equal(process.dead, false, 'absence is checked independently of the dead flag')
  expect.equal(env.processBoundary.retained(), 0, 'removing the final process prunes every retained row wrapper')
  table.insert(env.native.events.processes, process)
  env.running:step(0)
  local _, returned = env.running:discover(env.ui, PANEL, 'applications')
  expect.truthy(returned.items[1].id ~= token, 'a removed process gets a new token if it reappears')
  token = returned.items[1].id
  geometry, list = env.running:discover(env.ui, PANEL, 'applications')
  env.running:aim(geometry, list.items[1].bounds.x + 10, list.items[1].bounds.y + 10)
  env.running:step(0)
  env.running:button('right', 'trigger', true)
  env.running:step(0)
  table.clear(env.native.events.processes)
  env.running:step(0)
  env.native.newProcess(81)
  env.running:step(0)
  env.running:button('right', 'trigger', false)
  env.running:step(0)
  expect.equal(env.choice.pinned, nil, 'a stale press cannot pin a replacement process with the same numeric id')
  local _, replacement = env.running:discover(env.ui, PANEL, 'applications')
  expect.truthy(replacement.items[1].id ~= token, 'replacement rows cannot reuse removed tokens')
  local seen = { [token] = true, [replacement.items[1].id] = true }
  for _ = 1, 100 do
    table.clear(env.native.events.processes)
    env.running:step(0)
    expect.equal(env.processBoundary.retained(), 0, 'an empty enumeration releases row wrappers')
    env.native.newProcess(81)
    env.running:step(0)
    local _, current = env.running:discover(env.ui, PANEL, 'applications')
    local currentToken = current.items[1].id
    expect.equal(seen[currentToken], nil, 'the token serial never repeats across removal and replacement')
    seen[currentToken] = true
    expect.equal(env.processBoundary.retained(), 1, 'only the currently enumerated row retains a wrapper')
  end
  env.running:close()
end)

test('adjacent exact high process ids keep VR selection, raw sources, and analysis profiles independent', function()
  local audio = require '@lunette-contracts/audio'
  local analysis = require '@lunette-contracts/audio-analysis'
  local env = fixture.boot { audioAnalysis = true }
  local first = env.native.newProcess(9007199254740991)
  local second = env.native.newProcess(9007199254740990)
  expect.equal(first.id - second.id, 1, 'adjacent adopted ids remain exactly represented')
  local sources = { { kind = 'process', process = first }, { kind = 'process', process = second } }
  local raw = env.running.session:observe(audio.capability)
  local analysed = env.running.session:observe(analysis.capability)
  local readers = {}
  local profiles = {}
  for index, source in sources do
    readers[index] = raw.service:open(raw.context, source)
    env.native.setAudioState(source, { kind = 'active', provenance = 'pipewire-client' })
    local samples = buffer.create(1024 * 8)
    for sample = 0, 1024 * 2 - 1 do
      buffer.writef32(samples, sample * 4, index * 0.125)
    end
    env.native.pushAudio(source, samples)
    local small = analysed.service:open(analysed.context, source, { size = 512 })
    local large = analysed.service:open(analysed.context, source, { size = 1024 })
    expect.equal(small.kind, 'success', 'each high-id source has its own first profile')
    expect.equal(large.kind, 'success', 'each high-id source has its own second profile')
    profiles[index] = { small.reader, large.reader }
  end
  expect.equal(env.native.events.audioOpened, 2, 'raw and analysis consumers share only within a source')
  env.running:step(0)
  for index, reader in readers do
    expect.equal(reader:snapshot().source.process, sources[index].process, 'raw source identity stays independent')
    expect.near(
      buffer.readf32(reader:snapshot().blocks[1]:copySamples(), 0),
      index * 0.125,
      1e-6,
      'raw PCM belongs to the selected source'
    )
    for _, profile in profiles[index] do
      expect.equal(profile:snapshot().source.process, sources[index].process, 'analysis retains source identity')
      expect.near(profile:snapshot().latest.rms, index * 0.125, 1e-6, 'each profile analyses its own PCM')
    end
  end
  fixture.open(env)
  local _, list = env.running:discover(env.ui, PANEL, 'applications')
  expect.equal(#list.items, 2, 'adjacent high-id processes remain separate application rows')
  expect.truthy(list.items[1].id ~= list.items[2].id, 'row tokens do not derive from rounded display labels')
  env.running:clickControl(env.ui, PANEL, 'applications', 'right', list.items[1].id)
  expect.equal(env.choice:source().process, first, 'the first VR row selects the first source')
  env.running:clickControl(env.ui, PANEL, 'applications', 'right', list.items[2].id)
  expect.equal(env.choice:source().process, second, 'the second VR row switches to the distinct adjacent source')
  for index, reader in readers do
    reader:close()
    for _, profile in profiles[index] do
      profile:close()
    end
  end
  expect.equal(env.native.events.audioClosed, 2, 'each independent source is released once')
  expect.equal(env.native.events.audioStreamsClosed, 2, 'each independent native stream is released once')
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
