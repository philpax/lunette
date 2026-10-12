local testing = require '@testing'
local native = require '@testing/native'
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local contract = require '@lunette-contracts/audio'
local config = require '@lunette-plugins/audio/config'
local frame = require '@lunette-contracts/frame'
local expect = testing.expect
local test = testing.suite()

local SYSTEM = { kind = 'system' }

type Observed = {
  instance: adapter.Instance<{}>,
  service: contract.Service,
  context: plugin.Context,
}
type Consumer = {
  publications: { contract.Snapshot },
  readers: { contract.Reader },
  activations: number,
  reader: contract.Reader,
  instance: adapter.Instance<{}>,
}

local function fixture(): (testing.Session, Observed, Observed)
  local session = testing.boot { 'frame', 'audio' }
  local first = session:observe(contract.capability)
  local second = session:observe(contract.capability)
  return session, first, second
end

local function advance(session: testing.Session): ()
  session.native.advanceFrame()
  session:update()
end

local function markSourceEndedWithLiveNativeReader(handle: native.AudioHandle): ()
  local close = handle.close
  local closed = false
  handle.dead = true
  handle.close = function(self: native.AudioHandle): boolean
    if closed then
      return false
    end
    closed = true
    self.dead = false
    return close(self)
  end
end

local function consumer(session: testing.Session, name: string, source: contract.Source): Consumer
  local observed = { publications = {}, readers = {}, activations = 0 }
  local definition = plugin.consumer {
    name = name,
    requires = { contract.capability, frame.capability },
    init = function(context: plugin.Context): ()
      observed.activations += 1
      local audio = context:require(contract.capability)
      local reader = audio:open(context, source)
      observed.reader = reader
      observed.readers[#observed.readers + 1] = reader
      context:require(frame.capability):onUpdate(context, {
        phase = 'input',
        order = 0,
        run = function()
          observed.publications[#observed.publications + 1] = reader:snapshot()
        end,
      })
    end,
  }
  observed.instance = session:use(definition.definition)
  return observed
end

test('the empty audio schema accepts defaults and rejects unknown options', function()
  local settings = config.schema.parse({}, 'audio settings')
  expect.equal(next(settings), nil, 'the resolved settings stay empty')
  expect.raises(function()
    config.schema.parse({ extra = true }, 'audio settings')
  end, 'not a declared field', 'the empty schema is closed')
end)

test('two_consumers_share_capture', function()
  local session = testing.boot { 'frame', 'audio' }
  local first = consumer(session, 'audio-first', SYSTEM)
  local second = consumer(session, 'audio-second', { kind = 'system' })
  local events = session.native.events
  expect.equal(events.audioOpened, 1, 'one native capture')
  expect.equal(events.audioStreamsOpened, 1, 'one native stream')
  expect.equal(events.audioSnapshots, 0, 'opening does not poll')
  expect.equal(first.reader:snapshot(), second.reader:snapshot(), 'initial publication identity')
  expect.equal(first.reader:snapshot().state.kind, 'starting', 'capture begins asynchronously')

  session.native.setAudioState(SYSTEM, { kind = 'active', provenance = 'pipewire-client' })
  session.native.pushAudio(SYSTEM, { 0.25, -0.5, 0.75, -1 }, {
    generation = 7,
    sequence = 11,
    startFrame = 90,
    gap = true,
    droppedFrames = 4,
  })
  expect.equal(#first.reader:snapshot().blocks, 0, 'pending PCM is not visible')
  advance(session)
  local snapshot = first.reader:snapshot()
  expect.equal(snapshot, second.reader:snapshot(), 'reader publication identity')
  expect.equal(first.publications[1], snapshot, 'polling precedes first input consumer')
  expect.equal(second.publications[1], snapshot, 'polling precedes second input consumer')
  for _ = 1, 12 do
    expect.equal(first.reader:snapshot(), snapshot, 'repeated snapshots do not drain')
  end
  expect.equal(events.audioSnapshots, 1, 'one native poll for two consumers')
  expect.equal(events.audioCopies, 0, 'publication does not copy PCM')
  expect.equal(snapshot.frameGeneration, 1, 'native frame generation')
  expect.equal(snapshot.state.provenance, 'pipewire-client', 'native attribution provenance')
  expect.truthy(table.isfrozen(snapshot), 'immutable snapshot')
  expect.truthy(table.isfrozen(snapshot.source), 'immutable descriptor')
  expect.truthy(table.isfrozen(snapshot.state), 'immutable state')
  expect.truthy(table.isfrozen(snapshot.blocks), 'immutable block collection')
  local block = snapshot.blocks[1]
  expect.truthy(table.isfrozen(block), 'immutable block metadata')
  expect.equal(block.frameCount, 2, 'complete stereo frames')
  expect.equal(block.sampleRate, 48000, 'sample rate')
  expect.equal(block.channels, 2, 'channel count')
  expect.equal(block.generation, 7, 'stream generation')
  expect.equal(block.sequence, 11, 'block sequence')
  expect.equal(block.startFrame, 90, 'sample-time position')
  expect.equal(block.timing, 'sample-frames', 'honest timing kind')
  expect.equal(block.gap, true, 'gap metadata')
  expect.equal(block.droppedFrames, 4, 'loss metadata')
  local a, b = block:copySamples(), block:copySamples()
  expect.equal(buffer.len(a), 16, 'interleaved F32 byte count')
  expect.near(buffer.readf32(a, 0), 0.25, 0.00001, 'left sample')
  buffer.writef32(a, 0, 99)
  expect.near(buffer.readf32(b, 0), 0.25, 0.00001, 'independent sample copy')

  session.native.pushAudio(SYSTEM, { 0, 0 })
  expect.equal(first.reader:snapshot(), snapshot, 'mid-frame injection preserves publication')
  advance(session)
  expect.equal(events.audioSnapshots, 2, 'one poll on the next frame')
  expect.equal(first.reader:snapshot(), second.reader:snapshot(), 'next frame shared identity')
  expect.equal(first.reader:snapshot().blocks[1].sequence, 12, 'next block arrives once')
  expect.equal(snapshot.blocks[1], block, 'retained publication remains valid')
  expect.near(buffer.readf32(block:copySamples(), 0), 0.25, 0.00001, 'retained PCM remains valid')
end)

test('audio_last_reader_releases_source', function()
  local session, first, second = fixture()
  local a = first.service:open(first.context, SYSTEM)
  local b = second.service:open(second.context, SYSTEM)
  local events = session.native.events
  local staleService, staleOwner = first.service, first.context
  a:close()
  a:close()
  expect.equal(events.audioClosed, 0, 'closing one owner leaves shared capture alive')
  expect.equal(a:snapshot().state.kind, 'ended', 'closed reader is terminal')
  expect.equal(a:snapshot(), a:snapshot(), 'closed snapshot identity is stable')
  expect.equal(b:snapshot().state.kind, 'starting', 'independent owner remains live')
  first.instance:disable()
  expect.raises(function()
    staleService:open(staleOwner, SYSTEM)
  end, nil, 'an inactive owner cannot reacquire')
  expect.equal(events.audioOpened, 1, 'stale owner rejection precedes native acquisition')
  expect.equal(events.audioClosed, 0, 'already closed owner does not release another reader')
  second.instance:disable()
  expect.equal(events.audioClosed, 1, 'last owner releases capture')
  expect.equal(events.audioStreamsClosed, 1, 'last owner releases native stream')
  b:close()
  expect.equal(events.audioClosed, 1, 'close after owner cleanup is idempotent')
  second.instance:enable()
  local replacement = second.service:open(second.context, SYSTEM)
  expect.equal(events.audioOpened, 2, 'opening again acquires a new capture')
  replacement:close()
  expect.equal(events.audioClosed, 2, 'new capture has an independent lifetime')
end)

test('ended captures release their native reader on last reader close and provider shutdown', function()
  local session, observed = fixture()
  local events = session.native.events
  local reader = observed.service:open(observed.context, SYSTEM)
  local handle = events.audio[1]
  markSourceEndedWithLiveNativeReader(handle)
  advance(session)
  expect.equal(reader:snapshot().state.kind, 'ended', 'ended capture publishes a terminal state')
  expect.equal(events.audioStreamsOpened, 1, 'native stream remains registered before release')
  expect.equal(events.audioClosed, 0, 'source end does not close the native reader')
  reader:close()
  expect.equal(events.audioClosed, 1, 'last reader closes the native reader')
  expect.equal(events.audioStreamsClosed, 1, 'last reader releases the native stream')
  reader:close()
  expect.equal(events.audioClosed, 1, 'repeated close does not close the native reader twice')
  expect.equal(events.audioStreamsClosed, 1, 'repeated close does not release the native stream twice')

  local shutdownReader = observed.service:open(observed.context, SYSTEM)
  markSourceEndedWithLiveNativeReader(events.audio[2])
  advance(session)
  expect.equal(shutdownReader:snapshot().state.kind, 'ended', 'second capture also reaches ended state')
  session.instances.audio:disable()
  expect.equal(events.audioClosed, 2, 'provider shutdown closes the ended native reader')
  expect.equal(events.audioStreamsClosed, 2, 'provider shutdown releases the ended native stream')
  shutdownReader:close()
  session:close()
  expect.equal(events.audioClosed, 2, 'shutdown cleanup remains idempotent')
  expect.equal(events.audioStreamsClosed, 2, 'shutdown releases the native stream exactly once')
end)

test('provider interruptions release every owner and reopen only on recovery', function()
  local session = testing.boot { 'frame', 'audio' }
  local first = consumer(session, 'audio-first-interruption', SYSTEM)
  local second = consumer(session, 'audio-second-interruption', SYSTEM)
  local process = session.native.newProcess(410, { 'fixture-player', '--quiet' })
  local third = consumer(session, 'audio-process-interruption', { kind = 'process', process = process })
  local events = session.native.events
  expect.equal(events.audioOpened, 2, 'independent source captures')
  session.instances.audio:disable()
  expect.equal(events.audioClosed, 2, 'provider outage releases all sources')
  expect.equal(first.reader:snapshot().state.kind, 'ended', 'first reader closes')
  expect.equal(second.reader:snapshot().state.kind, 'ended', 'second reader closes')
  expect.equal(third.reader:snapshot().state.kind, 'ended', 'process reader closes')
  advance(session)
  expect.equal(events.audioSnapshots, 0, 'outage does not poll')
  session.instances.audio:enable()
  expect.equal(first.activations, 2, 'first consumer recovers')
  expect.equal(second.activations, 2, 'second consumer recovers')
  expect.equal(third.activations, 2, 'process consumer recovers')
  expect.equal(events.audioOpened, 4, 'recovered consumers share fresh captures')
  expect.equal(first.readers[1]:snapshot().state.kind, 'ended', 'retained old reader stays terminal')
  session.instances.frame:disable()
  expect.equal(events.audioClosed, 4, 'frame outage releases dependent captures')
  session.instances.frame:enable()
  expect.equal(events.audioOpened, 6, 'frame recovery reactivates capture owners')
  session:close()
  expect.equal(events.audioClosed, 6, 'shutdown releases recovered captures')
  for _, reader in first.readers do
    reader:close()
    expect.equal(reader:snapshot().state.kind, 'ended', 'every retained activation stays closed')
  end
end)

test('starting no audio idle and recoverable outages preserve source identity', function()
  local session, observed = fixture()
  local process = session.native.newProcess(520, { 'fixture-media' })
  local source = { kind = 'process', process = process }
  local reader = observed.service:open(observed.context, source)
  expect.equal(reader:snapshot().state.kind, 'starting', 'initial state')
  local states = {
    { kind = 'starting' },
    { kind = 'idle' },
    { kind = 'active', provenance = 'application-metadata' },
    { kind = 'unavailable', reason = 'no-server', detail = 'fixture server is absent' },
    { kind = 'unavailable', reason = 'no-default-sink', detail = 'fixture sink is absent' },
    { kind = 'unavailable', reason = 'invalid-default-sink', detail = 'fixture metadata is invalid' },
    { kind = 'unavailable', reason = 'permission-denied', detail = 'fixture permission denied' },
    { kind = 'unavailable', reason = 'unsupported-format', detail = 'fixture format rejected' },
    { kind = 'unavailable', reason = 'unresolved-attribution', detail = 'fixture identity unresolved' },
    { kind = 'unavailable', reason = 'capacity-exceeded', detail = 'fixture capacity exhausted' },
    { kind = 'unavailable', reason = 'graph-failure', detail = 'fixture graph failed' },
    { kind = 'starting' },
    { kind = 'active', provenance = 'pipewire-client' },
  }
  for _, state in states do
    session.native.setAudioState(source, state)
    advance(session)
    local snapshot = reader:snapshot()
    expect.equal(snapshot.source.process, process, 'the selected logical process is retained')
    expect.equal(snapshot.state.kind, state.kind, 'expected capture state is returned')
    expect.equal(snapshot.state.reason, state.reason, 'expected reason is preserved')
    expect.equal(snapshot.state.detail, state.detail, 'diagnostic detail is preserved')
    expect.equal(#snapshot.blocks, 0, 'no PCM is fabricated')
  end
  session.native.pushAudio(source, { 0, 0, 0, 0 })
  advance(session)
  expect.equal(reader:snapshot().state.kind, 'active', 'silence remains active')
  expect.equal(#reader:snapshot().blocks, 1, 'silent PCM is not idleness')
  process.dead = true
  advance(session)
  expect.equal(reader:snapshot().state.kind, 'ended', 'ended process is terminal')
  expect.equal(session.native.events.audioOpened, 1, 'outages do not replace the selected source')
end)

test('process enumeration labels logical handles from live associated windows without name matching', function()
  local session, observed = fixture()
  local fake = session.native
  local a = fake.newProcess(630)
  local b = fake.newProcess(631)
  local unnamed = fake.newProcess(632)
  local ended = fake.newProcess(633)
  ended.dead = true
  local windowOnly = fake.newProcess(634)
  table.remove(fake.events.processes, table.find(fake.events.processes, windowOnly))
  local first = fake.newWindow(640, 'same-app', a)
  local second = fake.newWindow(641, 'same-app', a)
  local application = fake.newWindow(642, 'same-app', b)
  local associated = fake.newWindow(643, 'other-app', windowOnly)
  local closed = fake.newWindow(644, 'closed-app', unnamed)
  first.title, second.title = 'Fixture playback', 'Other playback window'
  application.title, associated.title = '', 'Associated client'
  closed.dead = true
  fake.events.windows = { second, application, associated, closed, first }
  local reader = observed.service:open(observed.context, { kind = 'process', process = b })
  fake.setAudioState({ kind = 'process', process = b }, { kind = 'idle' })
  advance(session)
  observed.context:on { event = lunette.onWindowOpened, run = function() end }
  local listed = observed.service:processes()
  expect.equal(#listed, 4, 'live logical processes deduplicate windows and include window associations')
  expect.equal(listed[1].process, a, 'first logical handle')
  expect.equal(listed[1].label, 'Fixture playback', 'title of the lowest-id live window precedes its app ID')
  expect.equal(listed[1].state, nil, 'unopened process status is optional')
  expect.equal(listed[2].process, b, 'same application name does not merge logical processes')
  expect.equal(listed[2].label, 'same-app', 'empty title falls back to the associated app ID')
  expect.equal(listed[2].state.kind, 'idle', 'opened source status uses cached publication')
  expect.equal(listed[3].label, 'Process 632', 'closed windows do not label a live process')
  expect.equal(listed[4].process, windowOnly, 'window association comes from native handle')
  expect.equal(listed[4].label, 'Associated client', 'window-only process receives its associated title')

  application.title = first.title
  listed = observed.service:processes()
  expect.equal(listed[1].label, listed[2].label, 'duplicate labels remain display text rather than identity')
  expect.equal(listed[1].process, a, 'first duplicate label retains its process')
  expect.equal(listed[2].process, b, 'second duplicate label retains its process')
  first.dead = true
  listed = observed.service:processes()
  expect.equal(listed[1].label, 'Other playback window', 'another live window replaces a closed label')
  second.dead = true
  application.title, application.appId = '', ''
  listed = observed.service:processes()
  expect.equal(listed[1].label, 'Process 630', 'closing all associated windows restores the process fallback')
  expect.equal(listed[2].label, 'Process 631', 'empty title and app ID restore the process fallback')
  application.title, application.appId = nil, nil
  listed = observed.service:processes()
  expect.equal(listed[2].label, 'Process 631', 'missing title and app ID restore the process fallback')
  expect.equal(fake.events.audioOpened, 1, 'enumeration does not acquire audio')
  expect.equal(fake.events.audioSnapshots, 1, 'enumeration does not poll audio')
  expect.equal(reader:snapshot().source.process, b, 'label changes do not change the source')
end)

test('source descriptors reject unknown fields and native validation rejects forged handles', function()
  local session, observed = fixture()
  local audio, owner = observed.service, observed.context
  local invalid = {
    false,
    {},
    { kind = 'microphone' },
    { kind = 'system', process = {} },
    { kind = 'system', extra = true },
    { kind = 'process', pid = 700 },
    { kind = 'process' },
    setmetatable({ kind = 'system' }, {}),
  }
  for _, descriptor in invalid do
    expect.raises(function()
      audio:open(owner, descriptor)
    end, 'audio open', 'closed source descriptor')
  end
  expect.equal(session.native.events.audioOpened, 0, 'invalid descriptors acquire nothing')
  local process = session.native.newProcess(710, { 'fixture-validation' })
  local reader = audio:open(owner, { kind = 'process', process = process })
  expect.raises(function()
    audio:open(owner, { kind = 'process', process = { id = process.id, dead = false } })
  end, 'unregistered audio process', 'matching id cannot bypass native validation')
  expect.equal(session.native.events.audioOpened, 1, 'forged handle leaves valid shared capture unchanged')
  local descriptor = { kind = 'system' }
  local system = audio:open(owner, descriptor)
  descriptor.kind = 'process'
  expect.equal(system.source.kind, 'system', 'caller mutation does not change the source')
  reader:close()
  system:close()
end)

test('native programming errors reach callers and the protected frame boundary', function()
  local session, observed = fixture()
  local original = lunette.openAudio
  lunette.openAudio = function()
    error 'fixture native open programming error'
  end
  expect.raises(function()
    observed.service:open(observed.context, SYSTEM)
  end, 'native open programming error', 'open errors are not unavailable states')
  lunette.openAudio = original
  expect.equal(session.native.events.audioOpened, 0, 'failed acquisition leaves no capture')
  local reader = observed.service:open(observed.context, SYSTEM)
  local handle = session.native.events.audio[1]
  local snapshot = handle.snapshot
  handle.snapshot = function()
    error 'fixture native snapshot programming error'
  end
  advance(session)
  local reports = session.native.events.reported
  expect.equal(#reports, 1, 'poll error reaches the protected frame boundary')
  expect.truthy(reports[1].message:find 'native snapshot programming error', 'original error is retained')
  expect.equal(reader:snapshot().state.kind, 'starting', 'programming error is not an expected outage')
  handle.snapshot = snapshot
  advance(session)
  reader:close()
end)

test('owner cancellation during capture acquisition releases the partial resource', function()
  local session, observed = fixture()
  local original = lunette.openAudio
  lunette.openAudio = function(source: native.AudioSource): native.AudioHandle
    local capture = original(source)
    observed.instance:disable()
    return capture
  end
  expect.raises(function()
    observed.service:open(observed.context, SYSTEM)
  end, 'cancelled', 'cancelled resource registration')
  lunette.openAudio = original
  expect.equal(session.native.events.audioOpened, 1, 'native acquisition happened')
  expect.equal(session.native.events.audioClosed, 1, 'cancelled registration runs its inverse')
  expect.equal(session.native.events.audioStreamsClosed, 1, 'partial stream is released')
  observed.instance:enable()
  local reader = observed.service:open(observed.context, SYSTEM)
  expect.equal(session.native.events.audioOpened, 2, 'recovery acquires a fresh capture')
  reader:close()
end)

return test
