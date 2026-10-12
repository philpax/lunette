local testing = require '@testing'
local diagnostics = require '../init'
local readout = require '../readout'
local history = require '../history'
local audio = require '@lunette-contracts/audio'
local analysis = require '@lunette-contracts/audio-analysis'
local expect = testing.expect
local test = testing.suite()
local lunette = require '@lunette'
local SYSTEM: lunette.AudioSource = { kind = 'system' }
type BootSession = testing.Session & { native: testing.Native }

local function advance(session: BootSession)
  session.native.advanceFrame()
  session:update()
end

test('diagnostics are inert until explicitly enabled and release their readers', function()
  local session = testing.boot { 'frame', 'audio', 'audio-analysis' }
  local instance = session:use(diagnostics.definition)
  expect.equal(session.native.events.audioOpened, 0, 'default diagnostics do not acquire capture')
  instance:disable()
  local enabled = session:use(diagnostics.definition, { enabled = true })
  expect.equal(session.native.events.audioOpened, 1, 'enabled raw and feature readers share capture')
  advance(session)
  enabled:disable()
  expect.equal(session.native.events.audioClosed, 1, 'disabling diagnostics releases capture')
end)

test('readout reports public source format identity loss bands and provenance', function()
  local session = testing.boot { 'frame', 'audio', 'audio-analysis' }
  local rawOwner = session:observe(audio.capability)
  local featureOwner = session:observe(analysis.capability)
  local raw = rawOwner.service:open(rawOwner.context, SYSTEM)
  local opened = featureOwner.service:open(featureOwner.context, SYSTEM, { size = 512 })
  expect.equal(opened.kind, 'success', 'analysis opens')
  local samples = table.create(1024, 0.25)
  session.native.setAudioState(SYSTEM, { kind = 'active', provenance = 'application-metadata' })
  session.native.pushAudio(SYSTEM, samples, { generation = 7, sequence = 11, gap = true, droppedFrames = 4 })
  advance(session)
  local shown = readout.format(raw:snapshot(), opened.reader:snapshot())
  for _, expected in
    {
      'source=system',
      'state=active',
      'provenance=application-metadata',
      '48000 Hz/2 channels/F32LE',
      'seq=11 generation=7',
      'gap=true dropped=4',
      'size=512 hop=128',
      'RMS=0.2500',
      'powers bass=',
    }
  do
    expect.truthy(shown:find(expected, 1, true), expected)
  end
  session.native.setAudioState(SYSTEM, { kind = 'unavailable', reason = 'no-server', detail = 'fixture server absent' })
  advance(session)
  expect.truthy(readout.format(raw:snapshot(), nil):find('no-server: fixture server absent', 1, true), 'outage detail')
end)

test('a process source uses a live handle without persisting or substituting its identity', function()
  local session = testing.boot { 'frame', 'audio', 'audio-analysis' }
  local process = session.native.newProcess(901, { 'fixture-player' })
  local selected = { kind = 'process', process = process }
  local instance = session:use(diagnostics.definition, {
    enabled = true,
    source = function(): audio.Source
      return selected
    end,
  })
  local observed = session:observe(audio.capability)
  local reader = observed.service:open(observed.context, selected)
  expect.equal(readout.source(reader.source), 'process 901', 'logical process id')
  process.dead = true
  advance(session)
  expect.equal(reader:snapshot().state.kind, 'ended', 'ended identity is not replaced')
  expect.equal(session.native.events.audioOpened, 1, 'diagnostics never falls back to system audio')
  reader:close()
  instance:disable()
  expect.equal(session.native.events.audioClosed, 1, 'all process readers close')
end)

test('enabled diagnostics preserve a transient gap until the next interval report', function()
  local session = testing.boot { 'frame', 'audio', 'audio-analysis' }
  session:use(diagnostics.definition, { enabled = true, interval = 1 })
  session.native.setAudioState(SYSTEM, { kind = 'active' })
  session.native.pushAudio(SYSTEM, table.create(1024, 0.25), { generation = 1, sequence = 1 })
  session.native.advanceFrame()
  session:update(0.1)
  table.clear(session.native.events.logs)
  session.native.pushAudio(SYSTEM, table.create(1024, 0.25), {
    generation = 2,
    sequence = 1,
    gap = true,
    droppedFrames = 7,
  })
  session.native.advanceFrame()
  session:update(0.1)
  expect.equal(#session.native.events.logs, 0, 'no early interval report')
  session.native.advanceFrame()
  session:update(1)
  expect.equal(#session.native.events.logs, 1, 'one interval report')
  local report = session.native.events.logs[1][1]
  expect.truthy(report:find('PCM: no blocks', 1, true), 'current publication is empty')
  expect.truthy(report:find('rawGaps=1 rawDropped=7 generationChanges=1', 1, true), 'earlier loss remains visible')
end)

test('interval history retains transient loss and generation changes without replaying publications', function()
  local session = testing.boot { 'frame', 'audio', 'audio-analysis' }
  local rawOwner = session:observe(audio.capability)
  local featureOwner = session:observe(analysis.capability)
  local raw = rawOwner.service:open(rawOwner.context, SYSTEM)
  local opened = featureOwner.service:open(featureOwner.context, SYSTEM, { size = 512 })
  expect.equal(opened.kind, 'success', 'analysis opens')
  local pending = history.new()
  session.native.setAudioState(SYSTEM, { kind = 'active' })
  session.native.pushAudio(SYSTEM, table.create(1024, 0.25), { generation = 1, sequence = 1 })
  advance(session)
  history.observe(pending, raw:snapshot(), opened.reader:snapshot())
  history.take(pending)
  session.native.pushAudio(SYSTEM, table.create(1024, 0.25), {
    generation = 2,
    sequence = 1,
    gap = true,
    droppedFrames = 9,
  })
  advance(session)
  local snapshot = raw:snapshot()
  local features = opened.reader:snapshot()
  history.observe(pending, snapshot, features)
  history.observe(pending, snapshot, features)
  advance(session)
  history.observe(pending, raw:snapshot(), opened.reader:snapshot())
  local shown = history.take(pending)
  expect.truthy(shown:find('rawGaps=1 rawDropped=9 generationChanges=1', 1, true), 'transient raw loss persists')
  expect.truthy(shown:find('analysisGaps=1', 1, true), 'transient analysis gap persists')
  local empty = history.take(pending)
  expect.truthy(empty:find('rawGaps=0 rawDropped=0 generationChanges=0', 1, true), 'reported counters reset')
end)

return test
