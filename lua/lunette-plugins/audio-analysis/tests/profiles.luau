local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/audio-analysis'
local fixture = require './support/profile-fixture'
local test = testing.suite()
local SYSTEM: contract.Source = { kind = 'system' }
local api = require '@lunette'
type AudioSource = api.AudioSource
type AudioCapture = api.AudioCapture

type Observed = testing.Observed<contract.Service> & { service: contract.Service, context: testing.Context }
type FailureKind = 'invalid-options' | 'capacity-exceeded'
local function denied(observed: Observed, source: unknown, options: unknown, kind: FailureKind): ()
  local result = observed.service:open(observed.context, source :: contract.Source, options :: contract.Options?)
  expect.equal(result.kind, kind, 'the structured failure kind')
  expect.truthy(type(result.detail) == 'string' and #result.detail > 0, 'the failure detail')
  expect.equal(result.reader, nil, 'a failure has no reader')
  expect.truthy(table.isfrozen(result), 'the immutable failure')
end

test('two_consumers_share_capture_and_analysis', function()
  local current = fixture.new()
  local session, counts = current.session, current.counts
  local first, second = current.observed, session:observe(contract.capability)
  local a = fixture.open(first, SYSTEM)
  local b = fixture.open(second, { kind = 'system' }, { size = 2048, hop = 512 })
  expect.equal(counts.fftNew, 1, 'one FFT for duplicate profiles')
  expect.equal(counts.analyzerNew, 1, 'one analyzer for duplicate profiles')
  expect.equal(session.native.events.audioOpened, 1, 'one raw reader')
  expect.equal(a:snapshot(), b:snapshot(), 'initial publication identity')
  session.native.setAudioState(SYSTEM, { kind = 'active' })
  session.native.pushAudio(SYSTEM, fixture.signal(2048), { generation = 3, sequence = 8, startFrame = 100 })
  current.advance()
  local publication = a:snapshot()
  expect.equal(publication, b:snapshot(), 'shared immutable analysis publication')
  expect.equal(session.native.events.audioCopies, 1, 'one PCM copy for duplicate profiles')
  expect.equal(counts.transforms, 2, 'one stereo FFT hop')
  expect.equal(counts.beginFrames, 1, 'one beginFrame for the profile publication')
  expect.equal(#publication.hops, 1, 'one complete window')
  expect.equal(publication.frameGeneration, 1, 'native frame publication generation')
  expect.equal(publication.hops[1].endFrame, 2148, 'exclusive sample-time position')
  expect.near(publication.latest.midPower, 0.125, 1e-8, 'the exact tone band power')
  expect.equal(publication.latest.onset, nil, 'latest never contains an impulse')
  for _ = 1, 10 do
    expect.equal(a:snapshot(), publication, 'repeated snapshots do not process again')
  end
  session:update()
  expect.equal(counts.beginFrames, 1, 'repeated native generation never opens another batch')
  expect.equal(counts.transforms, 2, 'repeated native generation never repeats an FFT')
  expect.equal(session.native.events.audioCopies, 1, 'repeated native generation never copies PCM')
  a:close()
  expect.equal(session.native.events.audioClosed, 0, 'another owner retains the shared profile')
  first.instance:disable()
  expect.equal(session.native.events.audioClosed, 0, 'already closed owner does not release another reader')
  second.instance:disable()
  expect.equal(session.native.events.audioClosed, 1, 'last owner releases the raw reader')
  expect.equal(a:snapshot().state.kind, 'ended', 'closed reader is terminal')
  expect.equal(b:snapshot().state.kind, 'ended', 'owner cleanup closes the reader')
  b:close()
  expect.equal(session.native.events.audioClosed, 1, 'close is idempotent after cleanup')
end)

test('distinct_profiles_share_one_source_copy_and_reject_a_third_before_FFT_allocation', function()
  local current = fixture.new()
  local observed, session, counts = current.observed, current.session, current.counts
  local a = fixture.open(observed, SYSTEM, { size = 512 })
  local b = fixture.open(observed, SYSTEM, { size = 1024 })
  expect.equal(counts.fftNew, 2, 'two distinct profile FFTs')
  expect.equal(session.native.events.audioOpened, 1, 'distinct profiles use one raw reader')
  denied(observed, SYSTEM, { size = 2048 }, 'capacity-exceeded')
  expect.equal(counts.fftNew, 2, 'capacity failure allocates no FFT or twiddles')
  expect.equal(session.native.events.audioOpened, 1, 'capacity failure acquires no raw reader')
  local duplicate = fixture.open(observed, SYSTEM, { size = 512, hop = 128 })
  expect.equal(counts.fftNew, 2, 'duplicates remain valid at the per-source limit')
  session.native.setAudioState(SYSTEM, { kind = 'active' })
  session.native.pushAudio(SYSTEM, fixture.signal(1024), { sequence = 1 })
  current.advance()
  expect.equal(session.native.events.audioCopies, 1, 'one source PCM copy shared by both profiles')
  expect.equal(counts.beginFrames, 2, 'one beginFrame per distinct profile')
  expect.equal(counts.transforms, 12, 'five small stereo hops and one large stereo hop')
  expect.equal(a:snapshot(), duplicate:snapshot(), 'duplicate small profile shares output')
  expect.equal(#a:snapshot().hops, 5, 'small profile hop count')
  expect.equal(#b:snapshot().hops, 1, 'large profile hop count')
  duplicate:close()
  a:close()
  local replacement = fixture.open(observed, SYSTEM, { size = 2048 })
  expect.equal(counts.fftNew, 3, 'last-reader release frees one distinct-profile slot')
  b:close()
  expect.equal(session.native.events.audioClosed, 0, 'replacement retains the source')
  replacement:close()
  expect.equal(session.native.events.audioClosed, 1, 'last distinct profile releases the source')
end)

test('eight_runtime_profiles_allow_duplicates_but_reject_new_work_until_a_slot_is_released', function()
  local current = fixture.new()
  local observed, session, counts = current.observed, current.session, current.counts
  local readers, sources = {}, {}
  for index = 1, 4 do
    sources[index] = { kind = 'process', process = session.native.newProcess(1100 + index) }
    readers[#readers + 1] = fixture.open(observed, sources[index], { size = 512 })
    readers[#readers + 1] = fixture.open(observed, sources[index], { size = 1024 })
  end
  local fifth = { kind = 'process', process = session.native.newProcess(1200) }
  denied(observed, fifth, nil, 'capacity-exceeded')
  expect.equal(counts.fftNew, 8, 'runtime capacity rejection allocates no FFT')
  expect.equal(session.native.events.audioOpened, 4, 'runtime capacity rejection acquires no source')
  local duplicate = fixture.open(observed, sources[1], { size = 512 })
  expect.equal(counts.fftNew, 8, 'duplicate succeeds at runtime capacity')
  readers[1]:close()
  denied(observed, fifth, nil, 'capacity-exceeded')
  duplicate:close()
  local replacement = fixture.open(observed, fifth)
  expect.equal(counts.fftNew, 9, 'the last duplicate frees runtime capacity')
  expect.equal(session.native.events.audioOpened, 5, 'new source starts only after capacity is available')
  expect.equal(replacement.profile.size, 2048, 'the default size')
  expect.equal(replacement.profile.hop, 512, 'the default hop')
end)

test('invalid_options_have_closed_failures_and_no_capture_analyzer_or_FFT_allocations', function()
  local current = fixture.new()
  local observed, session, counts = current.observed, current.session, current.counts
  for _, options in
    {
      false,
      'profile',
      { size = 256 },
      { size = 0 / 0 },
      { size = 512, hop = 64 },
      { hop = math.huge },
      { size = '512' },
      { size = 512, fluxThreshold = 0.2 },
      { sampleRate = 48000 },
      setmetatable({}, {}),
    }
  do
    denied(observed, SYSTEM, options, 'invalid-options')
  end
  expect.equal(counts.fftNew, 0, 'invalid options allocate no FFT')
  expect.equal(counts.analyzerNew, 0, 'invalid options allocate no analyzer cache')
  expect.equal(session.native.events.audioOpened, 0, 'invalid options acquire no capture')
  local options = { size = 512 }
  local reader = fixture.open(observed, SYSTEM, options)
  options.size = 2048
  expect.equal(reader.profile.size, 512, 'caller option mutation cannot change the profile')
  expect.truthy(table.isfrozen(reader.profile), 'resolved options are immutable')
  observed.instance:disable()
  expect.raises(function()
    observed.service:open(observed.context, SYSTEM, { size = 17 })
  end, nil, 'inactive owners cannot request even a failed result')
end)

test('logical_process_sources_share_by_id_without_accepting_arbitrary_PIDs_or_forged_handles', function()
  local current = fixture.new()
  local observed, session = current.observed, current.session
  local process = session.native.newProcess(1300)
  local source = { kind = 'process', process = process }
  local a = fixture.open(observed, source, { size = 512 })
  local b = fixture.open(observed, { kind = 'process', process = process }, { size = 512 })
  expect.equal(a:snapshot(), b:snapshot(), 'equal logical sources share a profile')
  for _, invalid in
    {
      { kind = 'process', pid = 1300 },
      { kind = 'process', process = 1300 },
      { kind = 'process' },
      { kind = 'system', pid = 1300 },
      { kind = 'unknown' },
    }
  do
    expect.raises(function()
      observed.service:open(observed.context, invalid, { size = 512 })
    end, 'audio analysis')
  end
  expect.raises(function()
    observed.service:open(observed.context, { kind = 'process', process = { id = 1300 } }, { size = 512 })
  end, 'unregistered audio process', 'matching id cannot bypass raw native validation')
  expect.equal(session.native.events.audioOpened, 1, 'invalid descriptors leave shared capture untouched')
  local other = fixture.open(observed, { kind = 'process', process = session.native.newProcess(1301) }, { size = 512 })
  expect.truthy(other:snapshot() ~= a:snapshot(), 'different logical ids do not share')
end)

test('a_source_reopened_mid_frame_starts_at_the_next_native_publication', function()
  local current = fixture.new()
  local observed, session = current.observed, current.session
  local first = fixture.open(observed, SYSTEM, { size = 512 })
  session.native.setAudioState(SYSTEM, { kind = 'active' })
  session.native.pushAudio(SYSTEM, fixture.signal(512))
  current.advance()
  first:close()
  local replacement = fixture.open(observed, SYSTEM, { size = 512 })
  local initial = replacement:snapshot()
  session:update()
  expect.equal(replacement:snapshot(), initial, 'reopening does not replay the current publication')
  expect.equal(#replacement:snapshot().hops, 0, 'reopened readers begin without event replay')
  session.native.setAudioState(SYSTEM, { kind = 'active' })
  session.native.pushAudio(SYSTEM, fixture.signal(512, 512))
  current.advance()
  expect.equal(#replacement:snapshot().hops, 1, 'reopened source processes the next publication')
end)

test('owner_cancellation_during_capture_acquisition_releases_the_partial_profile', function()
  local current = fixture.new()
  local observed, session = current.observed, current.session
  local original = api.openAudio
  api.openAudio = function(source: AudioSource): AudioCapture
    local capture = original(source)
    observed.instance:disable()
    return capture
  end
  expect.raises(function()
    observed.service:open(observed.context, SYSTEM, { size = 512 })
  end, 'activation was cancelled')
  api.openAudio = original
  expect.equal(session.native.events.audioOpened, 1, 'the partial native acquisition')
  expect.equal(session.native.events.audioClosed, 1, 'cancelled registration releases the partial source')
  observed.instance:enable()
  local replacement = fixture.open(observed, SYSTEM, { size = 512 })
  expect.equal(session.native.events.audioOpened, 2, 'cancelled profile does not survive owner recovery')
  replacement:close()
  expect.equal(session.native.events.audioClosed, 2, 'replacement releases independently')
end)

return test
