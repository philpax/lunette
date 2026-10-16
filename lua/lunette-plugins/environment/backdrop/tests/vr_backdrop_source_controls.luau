local testing = require '@testing'
local fixture = require './support/source-controls'
local expect = testing.expect
local test = testing.suite()

local SOURCE = 'body/source/content/'
local FIRST = 'application-1'

-- Presses a row, runs `during` while the trigger is held, and releases.
local function holdRow(env: fixture.Environment, token: string, during: () -> ()): ()
  env.running:button('right', 'trigger', false)
  env.running:aim(fixture.rowGeometry(env, token), 0.5, 0.5)
  env.running:step(0)
  env.running:button('right', 'trigger', true)
  env.running:step(0)
  during()
  env.running:button('right', 'trigger', false)
  env.running:step(0)
end

local function rowText(env: fixture.Environment, token: string, field: string): string
  return assert(fixture.row(env, token)):descendant('face/' .. field).props.text
end

-- The token of the row that shows a process id.
local function tokenOf(env: fixture.Environment, id: number): string
  for _, token in fixture.rows(env) do
    if rowText(env, token, 'text/detail') == '#' .. tostring(id) then
      return token
    end
  end
  error(`no row shows process {id}`)
end

test('vr_backdrop_source_controls', function()
  local env = fixture.boot { settings = { sourceMode = 'attention' } }
  local process = env.native.newProcess(41)
  fixture.window(env, 41, process)
  for index = 42, 60 do
    env.native.newProcess(index)
  end
  env.running:step(0.75)
  env.running:step(0)
  expect.equal(fixture.visible(env), false, 'the panel starts closed')
  fixture.open(env)
  expect.truthy(env.choice.frozen, 'the menu action opens the panel and freezes attention')
  expect.truthy(fixture.visible(env), 'Backdrop is reachable through the controller menu')
  expect.truthy(
    string.find(rowText(env, FIRST, 'text/title'), 'org.fixture.Player', 1, true),
    'application ids label associated windows'
  )
  expect.equal(rowText(env, FIRST, 'text/detail'), '#41', 'the process id is only a distinguishing detail')
  expect.equal(fixture.node(env, SOURCE .. 'pin').props.disabledReason, nil, 'an attended application can be pinned')
  fixture.click(env, SOURCE .. 'pin')
  expect.equal(env.choice.mode, 'application', 'pin leaves attention mode')
  expect.equal(env.choice.pinned, process, 'pin retains the exact live process handle')
  env.running:step(0)
  expect.equal(assert(fixture.row(env, FIRST)).props.selected, true, 'the pinned row is selected')
  fixture.click(env, SOURCE .. 'mode/track/system')
  expect.equal(env.choice:source().kind, 'system', 'a controller explicitly selects the mix')
  env.running:step(0)
  expect.equal(
    fixture.node(env, SOURCE .. 'pin').props.disabledReason,
    'Pinning is available with the Attention source.',
    'the pin button explains why it is disabled'
  )
  holdRow(env, FIRST, function()
    process.dead = true
  end)
  expect.equal(env.choice.mode, 'system', 'a stale row invocation does not select its exited process')
  process.dead = false
  env.running:step(0)
  fixture.click(env, 'body/applications/content/scroll/rows/' .. tokenOf(env, 41))
  expect.equal(env.choice.pinned, process, 'an application row selects its live process handle')
  expect.equal(env.choice.mode, 'application', 'an application row enters pinned mode')
  process.dead = true
  expect.equal(env.choice:source().kind, 'process', 'a dead selected process does not fall back to the mix')
  process.dead = false
  env.running:step(0)
  fixture.click(env, 'body/reactive')
  expect.equal(env.choice:source(), nil, 'a controller disables audio reactivity')
  fixture.click(env, 'body/reactive')
  expect.equal(env.choice.reactive, true, 'a controller enables audio reactivity')
  fixture.click(env, 'body/enabled')
  expect.equal(env.enabled(), false, 'a controller disables the backdrop')
  fixture.click(env, 'body/enabled')
  expect.equal(env.enabled(), true, 'a controller enables the backdrop')
  fixture.slide(env, 'body/intensity/content/response', 0.25)
  fixture.slide(env, 'body/intensity/content/motion', 0.75)
  expect.equal(env.choice.response, 0.25, 'the response slider snaps to the Low detent')
  expect.equal(env.choice.motion, 0.75, 'the motion slider snaps to the High detent')
  env.running:step(0)
  expect.equal(
    fixture.node(env, 'body/intensity/content/response/heading/detent').props.text,
    'LOW',
    'the slider names the detent'
  )
  fixture.diagnostic(env, 'cells')
  expect.equal(env.choice.diagnostic, 'cells', 'a diagnostic view is controller accessible')
  fixture.diagnostic(env, 'none')
  expect.equal(env.choice.diagnostic, 'none', 'the diagnostic view turns off from the panel')
  local list = fixture.node(env, 'body/applications/content/scroll')
  env.running:aim(fixture.rowGeometry(env, tokenOf(env, 41)), 0.5, 0.5)
  env.running:step(0)
  env.running:axis('right', 0, 1)
  env.running:step(0.5)
  env.running:axis('right', 0, 0)
  env.running:step(0)
  expect.truthy(list.state.scrollY > 0, 'controller stick scrolling moves earlier application rows out of view')
  fixture.click(env, 'header/band/close')
  expect.equal(env.choice.frozen, false, 'the close button unfreezes attention')
  expect.equal(fixture.visible(env), false, 'closing hides the panel')
  fixture.open(env)
  expect.truthy(fixture.visible(env), 'the menu action opens the panel again')
  fixture.open(env)
  expect.equal(fixture.visible(env), false, 'the menu action toggles the panel closed')
  expect.equal(env.running:keyboardCount(), 0, 'the controls never request a physical or virtual keyboard')
  env.running:close()
end)

test('the status shows the source status and the attention notice', function()
  local env = fixture.boot()
  fixture.open(env)
  local status = fixture.node(env, SOURCE .. 'status').props.text
  expect.equal(string.find(status, 'System mix', 1, true), 1, 'the status names the source')
  fixture.click(env, SOURCE .. 'mode/track/attention')
  env.running:step(0)
  expect.equal(env.choice.mode, 'attention', 'the segment selects attention')
  expect.equal(
    fixture.node(env, SOURCE .. 'notice').props.text,
    'Attention pauses while this panel is open',
    'the panel explains why attention pauses'
  )
  expect.equal(
    fixture.node(env, SOURCE .. 'pin').props.disabledReason,
    'No application is attended.',
    'pinning needs an attended application'
  )
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
  expect.truthy(
    string.find(rowText(env, FIRST, 'text/title'), 'org.fixture.Player', 1, true),
    'window associations survive fresh process wrappers'
  )
  local stable = true
  holdRow(env, FIRST, function()
    for _ = 1, 300 do
      env.running:step(0)
      local tokens = fixture.rows(env, 4)
      stable = stable and #tokens == 1 and tokens[1] == FIRST
    end
  end)
  expect.equal(env.choice.mode, 'application', 'releasing a row after fresh-handle frames still pins it')
  expect.equal(env.choice.pinned, process, 'the row pins the same live process identity')
  expect.truthy(stable, 'unchanged rows keep their token through every frame')
  local boundary = assert(env.processBoundary)
  expect.truthy(boundary.retained() <= 2, 'retained wrappers are bounded by current rows and the pin')
  env.running:close()
end)

test('absent process rows release handles and never reuse a stale VR row token', function()
  local env = fixture.boot { freshProcesses = true }
  local boundary = assert(env.processBoundary)
  local process = env.native.newProcess(81)
  fixture.open(env)
  local token = fixture.rows(env)[1]
  holdRow(env, token, function()
    table.clear(env.native.events.processes)
  end)
  expect.equal(env.choice.pinned, nil, 'a process absent at invocation cannot be pinned even if its handle is live')
  expect.equal(process.dead, false, 'absence is checked independently of the dead flag')
  env.running:step(0)
  expect.equal(boundary.retained(), 0, 'removing the final process prunes every retained row wrapper')
  table.insert(env.native.events.processes, process)
  env.running:step(0)
  local returned = fixture.rows(env)[1]
  expect.truthy(returned ~= token, 'a removed process gets a new token if it reappears')
  holdRow(env, returned, function()
    table.clear(env.native.events.processes)
    env.running:step(0)
    env.native.newProcess(81)
    env.running:step(0)
  end)
  expect.equal(env.choice.pinned, nil, 'a stale press cannot pin a replacement process with the same numeric id')
  local replacement = fixture.rows(env)[1]
  expect.truthy(replacement ~= returned, 'replacement rows cannot reuse removed tokens')
  local seen = { [token] = true, [returned] = true, [replacement] = true }
  for _ = 1, 100 do
    table.clear(env.native.events.processes)
    env.running:step(0)
    env.running:step(0)
    expect.equal(boundary.retained(), 0, 'an empty enumeration releases row wrappers')
    env.native.newProcess(81)
    env.running:step(0)
    local current = fixture.rows(env)
    expect.equal(#current, 1, 'the replacement process has one row')
    expect.equal(seen[current[1]], nil, 'the token serial never repeats across removal and replacement')
    seen[current[1]] = true
    expect.equal(boundary.retained(), 1, 'only the currently enumerated row retains a wrapper')
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
  local tokens = fixture.rows(env)
  expect.equal(#tokens, 2, 'adjacent high-id processes remain separate application rows')
  expect.truthy(tokens[1] ~= tokens[2], 'row tokens do not derive from rounded display labels')
  fixture.click(env, 'body/applications/content/scroll/rows/' .. tokens[1])
  expect.equal(env.choice:source().process, first, 'the first VR row selects the first source')
  fixture.click(env, 'body/applications/content/scroll/rows/' .. tokens[2])
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

test('application row titles use nonempty titles, then application ids, then explicit process labels', function()
  local stores = require '../private/controls/stores'
  local selection = require '../private/selection/selection'
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
    local row = stores.rows(choice, { process }, { window })[1]
    expect.equal(row.title, expected, 'title case ' .. index)
    expect.equal(row.detail, '#' .. process.id, 'detail case ' .. index)
    expect.equal(row.trailing, 'audio provider unavailable', 'audio state case ' .. index)
    expect.equal(row.process, process, 'the label never replaces process identity')
  end
  local process = { id = 200, dead = false }
  choice.processStatuses = { { process = process, label = '' } }
  expect.equal(
    stores.rows(choice, { process }, {})[1].title,
    'Process 200',
    'an empty provider label also uses the explicit process fallback'
  )
  choice.processStatuses = { { process = process, label = 'player', state = { kind = 'idle' } } }
  local labelled = stores.rows(choice, { process }, {})[1]
  expect.equal(labelled.title, 'player', 'a provider label names a process without windows')
  expect.equal(labelled.trailing, 'silent', 'the provider audio state is shown')
  choice.processStatuses = {}
  expect.equal(
    stores.rows(choice, { process }, {})[1].title,
    'Process 200',
    'a process without windows or provider labels is explicitly named'
  )
end)

return test
