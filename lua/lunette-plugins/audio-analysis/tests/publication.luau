local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/audio-analysis'
local frame = require '@lunette-contracts/frame'
local fixture = require './support/profile-fixture'
local test = testing.suite()
local SYSTEM: contract.Source = { kind = 'system' }

type Fixture = fixture.Fixture
local native = require '@testing/native'
type AudioBlockOptions = native.AudioBlockOptions

local function active(current: Fixture): ()
  current.session.native.setAudioState(SYSTEM, { kind = 'active', provenance = 'pipewire-client' })
end

local function push(current: Fixture, count: number, offset: number, options: AudioBlockOptions?): ()
  current.session.native.pushAudio(SYSTEM, fixture.signal(count, offset), options)
end

test('analysis_publications_are_immutable_retained_and_visible_before_scene_updates', function()
  local current = fixture.new()
  local reader = fixture.open(current.observed, SYSTEM, { size = 512 })
  local seen = {}
  current.session:use(plugin.consumer({
    name = 'analysis-scene-observer',
    requires = { contract.capability, frame.capability },
    init = function(context: testing.Context)
      context:require(frame.capability):onUpdate(context, {
        phase = 'scene',
        run = function()
          seen[#seen + 1] = reader:snapshot()
        end,
      })
    end,
  }).definition)
  active(current)
  push(current, 1024, 0, { generation = 7, sequence = 4, startFrame = 80 })
  current.advance()
  local retained = reader:snapshot()
  expect.equal(seen[1], retained, 'analysis is published before scene updates')
  expect.equal(#retained.hops, 5, 'all complete sample-time hops are published')
  expect.equal(retained.endFrame, 1104, 'PCM publication end uses the complete raw block')
  for _, value in { retained, retained.source, retained.profile, retained.state, retained.hops, retained.latest } do
    expect.truthy(table.isfrozen(value), 'retained fields are immutable')
  end
  for index, hop in retained.hops do
    expect.truthy(table.isfrozen(hop), 'retained hop records are immutable')
    expect.equal(hop.generation, 7, 'the stream generation')
    expect.equal(hop.endFrame, 80 + 512 + (index - 1) * 128, 'ordered hop sample times')
    expect.near(hop.midPower, 0.125, 1e-8, 'the published power is not amplitude')
    expect.equal(hop.mid, nil, 'the public contract has no undocumented response amplitude')
  end
  expect.raises(function()
    retained.hops[1].midPower = 1
  end, nil, 'retained hops cannot be changed')
  local firstRecord = retained.hops[1]
  push(current, 1, 1024, { generation = 7, sequence = 5, startFrame = 1104 })
  current.advance()
  local zeroHop = reader:snapshot()
  expect.equal(#zeroHop.hops, 0, 'an incomplete window publishes an empty list')
  expect.equal(zeroHop.endFrame, 1105, 'zero-hop PCM advances the publication position')
  expect.equal(zeroHop.latest.endFrame, 1104, 'the last complete hop retains its own position')
  expect.equal(retained.endFrame, 1104, 'retained PCM timing stays immutable')
  current.advance()
  expect.equal(reader:snapshot().endFrame, 1105, 'a publication without PCM does not advance sample time')
  expect.equal(zeroHop.latest, retained.latest, 'zero-hop frames preserve steady values')
  expect.equal(zeroHop.latest.onset, nil, 'no cached onset is replayed')
  expect.equal(#retained.hops, 5, 'clearing the reusable analyzer batch cannot clear a retained list')
  expect.equal(retained.hops[1], firstRecord, 'retained hop identity stays valid')
  expect.equal(retained.frameGeneration, 1, 'retained native generation stays valid')
  reader:close()
  expect.equal(reader:snapshot().latest, nil, 'terminal readers clear steady values')
  expect.equal(reader:snapshot().endFrame, 1105, 'terminal readers retain the final PCM position')
end)

test('channel spectra publish on hops and steady values without extra transforms or mutable retained arrays', function()
  local current = fixture.new()
  local reader = fixture.open(current.observed, SYSTEM, { size = 512 })
  expect.equal(
    require('../').definition.provides[1].contract,
    'lunette/audio-analysis@2',
    'the required channel fields use capability version 2'
  )
  active(current)
  local samples = fixture.signal(1024)
  for frame = 0, 1023 do
    buffer.writef32(samples, frame * 8 + 4, 0)
  end
  current.session.native.pushAudio(SYSTEM, samples, { generation = 1, sequence = 0, startFrame = 0 })
  current.advance()
  local retained = reader:snapshot()
  expect.equal(current.counts.transforms, #retained.hops * 2, 'each hop still transforms only its two channels')
  local copies = {}
  for index, record in retained.hops do
    copies[index] = {}
    for _, field in { 'spectrum', 'leftSpectrum', 'rightSpectrum' } do
      expect.equal(#record[field], 8, 'the provider publishes eight bands')
      expect.truthy(table.isfrozen(record[field]), 'the provider publishes frozen spectra')
      copies[index][field] = table.clone(record[field])
      expect.raises(function()
        record[field][6] = 1
      end, nil, 'published spectrum elements reject mutation')
    end
    for band = 1, 8 do
      expect.equal(record.rightSpectrum[band], 0, 'the silent right channel remains silent')
      expect.near(record.spectrum[band], record.leftSpectrum[band] / 2, 1e-12, 'published combined power is averaged')
    end
    expect.near(record.leftSpectrum[6], 0.125, 1e-8, 'published left power is not a half contribution')
  end
  local latestHop = retained.hops[#retained.hops]
  for _, field in { 'spectrum', 'leftSpectrum', 'rightSpectrum' } do
    expect.equal(retained.latest[field], latestHop[field], 'steady values retain the last immutable channel arrays')
  end
  expect.equal(retained.latest.onset, nil, 'steady publication still contains no impulse')
  push(current, 1, 1024, { generation = 1, sequence = 1, startFrame = 1024 })
  current.advance()
  expect.equal(reader:snapshot().latest, retained.latest, 'a zero-hop publication retains all steady fields')
  push(current, 512, 1025, { generation = 1, sequence = 2, startFrame = 1025 })
  current.advance()
  expect.truthy(reader:snapshot().latest.rightSpectrum[6] > 0, 'later analysis uses different right-channel power')
  for index, record in retained.hops do
    for _, field in { 'spectrum', 'leftSpectrum', 'rightSpectrum' } do
      for band = 1, 8 do
        expect.equal(record[field][band], copies[index][field][band], 'retained spectra survive publication reuse')
      end
    end
  end
  current.session:close()
end)

test('multiple_hops_and_onsets_use_cumulative_PCM_delivery_time_including_the_partial_tail', function()
  local current = fixture.new()
  local reader = fixture.open(current.observed, SYSTEM, { size = 512 })
  expect.equal(reader:snapshot().endFrame, nil, 'an unopened PCM history has no position')
  active(current)
  current.session.native.pushAudio(SYSTEM, fixture.signal(1024, 0, 0.02), {
    generation = 3,
    sequence = 0,
    startFrame = 1000,
  })
  current.session.native.pushAudio(SYSTEM, fixture.signal(128, 1024, 0.5), {
    generation = 3,
    sequence = 1,
    startFrame = 2024,
  })
  push(current, 73, 1152, { generation = 3, sequence = 2, startFrame = 2152 })
  current.advance()
  local snapshot = reader:snapshot()
  expect.equal(snapshot.generation, 3, 'the delivery position names its stream generation')
  expect.equal(snapshot.endFrame, 2225, 'the final partial block advances cumulative PCM time')
  expect.equal(#snapshot.hops, 6, 'several blocks publish all complete hops once')
  for index, hop in snapshot.hops do
    expect.equal(hop.endFrame, 1512 + (index - 1) * 128, 'each hop has its own exclusive sample time')
    expect.equal(snapshot.endFrame - hop.endFrame, 713 - (index - 1) * 128, 'delivery ages include the partial tail')
  end
  local onset = snapshot.hops[6]
  expect.truthy(onset.onset > 0, 'the final completed hop contains a level-change onset')
  expect.near((snapshot.endFrame - onset.endFrame) / 48000, 73 / 48000, 1e-12, 'onset delivery age is not zero')
  expect.equal(snapshot.latest.endFrame, 2152, 'latest describes a window rather than the PCM publication end')
  current.advance()
  expect.equal(reader:snapshot().endFrame, 2225, 'no PCM does not invent sample-time advancement')
  expect.equal(#reader:snapshot().hops, 0, 'a later empty frame does not replay delivered onsets')
end)

test('gaps_and_generation_changes_reset_carry_and_flux_while_zero_hop_frames_do_not_replay_onsets', function()
  local current = fixture.new()
  local reader = fixture.open(current.observed, SYSTEM, { size = 512 })
  active(current)
  push(current, 384, 0, { generation = 1, sequence = 0, startFrame = 0 })
  current.advance()
  expect.equal(#reader:snapshot().hops, 0, 'the first carry is incomplete')
  push(current, 128, 384, { generation = 1, sequence = 1, startFrame = 384, gap = true, droppedFrames = 10 })
  current.advance()
  expect.truthy(reader:snapshot().gap, 'native packet loss is explicit')
  expect.equal(reader:snapshot().gapReason, 'discontinuity', 'the packet gap reason')
  expect.equal(reader:snapshot().droppedFrames, 10, 'native loss counts are preserved')
  expect.equal(#reader:snapshot().hops, 0, 'a native gap discards the previous carry')
  push(current, 384, 512, { generation = 1, sequence = 2, startFrame = 512 })
  current.advance()
  expect.equal(#reader:snapshot().hops, 1, 'a complete post-gap window')
  expect.equal(reader:snapshot().hops[1].flux, 0, 'post-gap flux establishes a baseline')
  expect.equal(reader:snapshot().hops[1].endFrame, 896, 'post-gap sample time')
  local retained = reader:snapshot()
  push(current, 512, 0, { generation = 2, sequence = 0, startFrame = 0 })
  current.advance()
  expect.equal(reader:snapshot().gapReason, 'generation', 'new stream generation is explicit')
  expect.equal(reader:snapshot().generation, 2, 'snapshot stream generation')
  expect.equal(reader:snapshot().hops[1].onset, 0, 'new stream has no inherited onset')
  expect.equal(retained.generation, 1, 'retained stream generation stays immutable')
  current.advance()
  expect.equal(#reader:snapshot().hops, 0, 'no PCM means no new hops')
end)

test('every_analysis_reset_clears_latest_until_a_fresh_window_and_never_replays_old_hops', function()
  for _, reset in
    {
      { reason = 'generation', generation = 2, sequence = 0, startFrame = 0 },
      { reason = 'discontinuity', generation = 1, sequence = 1, startFrame = 512, gap = true },
      { reason = 'discontinuity', generation = 1, sequence = 3, startFrame = 512 },
      { reason = 'discontinuity', generation = 1, sequence = 1, startFrame = 640 },
      { reason = 'capacity', generation = 1, sequence = 1, startFrame = 512, count = 12001 },
      { reason = 'invalidSamples', generation = 1, sequence = 1, startFrame = 512, invalid = true },
    }
  do
    local current = fixture.new()
    local reader = fixture.open(current.observed, SYSTEM, { size = 512 })
    active(current)
    push(current, 512, 0, { generation = 1, sequence = 0, startFrame = 0 })
    current.advance()
    local retained = reader:snapshot()
    local count = reset.count or 128
    local samples = fixture.signal(count, 512)
    if reset.invalid then
      buffer.writef32(samples, 0, 0 / 0)
    end
    current.session.native.pushAudio(SYSTEM, samples, {
      generation = reset.generation,
      sequence = reset.sequence,
      startFrame = reset.startFrame,
      gap = reset.gap,
    })
    current.advance()
    local snapshot = reader:snapshot()
    expect.equal(snapshot.gapReason, reset.reason, 'the reset reason is explicit')
    expect.equal(snapshot.latest, nil, 'a reset cannot retain the previous steady window')
    expect.equal(snapshot.generation, reset.generation, 'timing follows the processed generation')
    expect.equal(snapshot.endFrame, reset.startFrame + count, 'rejected or incomplete PCM advances delivery time')
    expect.equal(#snapshot.hops, 0, 'a reset without a fresh complete window emits no hop')
    current.advance()
    expect.equal(reader:snapshot().latest, nil, 'an active empty publication cannot restore old steady values')
    expect.equal(#reader:snapshot().hops, 0, 'an active empty publication cannot replay an old hop')
    push(current, 512, 512 + count, {
      generation = reset.generation,
      sequence = reset.sequence + 1,
      startFrame = reset.startFrame + count,
    })
    current.advance()
    expect.truthy(reader:snapshot().latest, 'a fresh complete window restores steady values')
    expect.equal(reader:snapshot().hops[1].onset, 0, 'the first fresh window establishes an onset baseline')
    expect.equal(retained.latest.endFrame, 512, 'resetting cannot mutate a retained steady publication')
    current.session:close()
  end
end)

test('a_reset_after_an_earlier_hop_in_one_publication_cannot_restore_latest_from_that_hop', function()
  local current = fixture.new()
  local reader = fixture.open(current.observed, SYSTEM, { size = 512 })
  active(current)
  push(current, 512, 0, { generation = 1, sequence = 0, startFrame = 0 })
  current.advance()
  push(current, 128, 512, { generation = 1, sequence = 1, startFrame = 512 })
  local invalid = fixture.signal(128, 640)
  buffer.writef32(invalid, 0, math.huge)
  current.session.native.pushAudio(SYSTEM, invalid, { generation = 1, sequence = 2, startFrame = 640 })
  current.advance()
  local snapshot = reader:snapshot()
  expect.equal(#snapshot.hops, 1, 'the complete event before the rejected block remains published')
  expect.equal(snapshot.hops[1].endFrame, 640, 'the earlier event retains its sample time')
  expect.equal(snapshot.gapReason, 'invalidSamples', 'the later rejected block resets history')
  expect.equal(snapshot.latest, nil, 'an event before the latest reset cannot become current steady data')
  expect.equal(snapshot.endFrame, 768, 'PCM position includes the rejected block')
  current.advance()
  expect.equal(reader:snapshot().latest, nil, 'an empty active publication cannot reintroduce the earlier hop')
  expect.equal(#reader:snapshot().hops, 0, 'the earlier event is not replayed')
end)

test('native_block_sequences_process_once_even_if_republished_in_a_new_frame', function()
  local current = fixture.new()
  local reader = fixture.open(current.observed, SYSTEM, { size = 512 })
  active(current)
  push(current, 512, 0, { generation = 1, sequence = 5, startFrame = 0 })
  current.advance()
  local before = current.counts.transforms
  push(current, 512, 0, { generation = 1, sequence = 5, startFrame = 0 })
  current.advance()
  expect.equal(#reader:snapshot().hops, 0, 'repeated native sequence creates no hops')
  expect.equal(current.counts.transforms, before, 'repeated native sequence creates no FFT')
  expect.equal(current.session.native.events.audioCopies, 1, 'repeated native sequence creates no PCM copy')
  expect.equal(current.counts.beginFrames, 2, 'a new publication still opens exactly one empty batch')
  local second = fixture.open(current.observed, SYSTEM, { size = 1024 })
  current.session:update()
  expect.equal(current.counts.beginFrames, 2, 'a newly opened profile does not replay the current publication')
  push(current, 1024, 512, { generation = 1, sequence = 6, startFrame = 512 })
  current.advance()
  expect.equal(#second:snapshot().hops, 1, 'the new profile starts on the next publication')
end)

test('expected_capture_outages_preserve_state_and_source_but_clear_latest_until_a_fresh_window', function()
  local current = fixture.new()
  local reader = fixture.open(current.observed, SYSTEM, { size = 512 })
  active(current)
  push(current, 512, 0, { generation = 4, sequence = 6, startFrame = 80 })
  current.advance()
  local retained = reader:snapshot()
  expect.truthy(retained.latest, 'capture begins with a completed steady window')
  for _, state in
    {
      { kind = 'unavailable', reason = 'no-server', detail = 'fixture server absent' },
      { kind = 'idle' },
      { kind = 'starting' },
      { kind = 'ended' },
    }
  do
    current.session.native.setAudioState(SYSTEM, state)
    current.advance()
    local snapshot = reader:snapshot()
    expect.equal(snapshot.state.kind, state.kind, 'capture state is preserved')
    expect.equal(snapshot.state.reason, state.reason, 'outage reason is preserved')
    expect.equal(snapshot.latest, nil, 'loss clears steady values')
    expect.equal(snapshot.endFrame, retained.endFrame, 'loss does not fabricate a PCM position')
    expect.equal(snapshot.source, reader.source, 'loss retains selected source identity')
    expect.equal(#snapshot.hops, 0, 'loss never fabricates completed hops')
  end
  active(current)
  push(current, 512, 0, { generation = 4, sequence = 6, startFrame = 80 })
  current.advance()
  expect.equal(reader:snapshot().latest, nil, 'active recovery with retained PCM cannot restore old steady values')
  expect.equal(#reader:snapshot().hops, 0, 'active recovery cannot replay an old hop')
  push(current, 128)
  current.advance()
  expect.equal(reader:snapshot().latest, nil, 'active recovery with incomplete PCM has no steady window')
  expect.equal(#reader:snapshot().hops, 0, 'incomplete recovery cannot replay an old hop')
  push(current, 384, 128)
  current.advance()
  expect.equal(reader:snapshot().hops[1].onset, 0, 'recovery resets onset history')
  expect.truthy(retained.latest, 'an outage cannot mutate a retained steady publication')
  expect.equal(current.session.native.events.audioOpened, 1, 'expected outages do not reopen capture')
end)

test('provider_deactivation_releases_all_profiles_and_old_readers_stay_terminal_after_recovery', function()
  local current = fixture.new()
  local observed, session = current.observed, current.session
  local first = fixture.open(observed, SYSTEM, { size = 512 })
  local second = fixture.open(observed, SYSTEM, { size = 1024 })
  session.instances['audio-analysis']:disable()
  expect.equal(session.native.events.audioClosed, 1, 'provider outage closes the shared raw reader')
  expect.equal(first:snapshot().state.kind, 'ended', 'the first retained reader closes')
  expect.equal(second:snapshot().state.kind, 'ended', 'the second retained reader closes')
  expect.equal(#first:snapshot().hops, 0, 'closed readers contain no event list')
  session.instances['audio-analysis']:enable()
  local replacement = fixture.open(observed, SYSTEM, { size = 512 })
  expect.equal(session.native.events.audioOpened, 2, 'recovery opens fresh source work')
  expect.equal(first:snapshot().state.kind, 'ended', 'recovery never revives old readers')
  replacement:close()
  first:close()
  expect.equal(session.native.events.audioClosed, 2, 'every activation releases once')
end)

test('unexpected_DSP_errors_reach_the_frame_boundary_instead_of_becoming_unavailable_states', function()
  local current = fixture.new()
  local reader = fixture.open(current.observed, SYSTEM, { size = 512 })
  local native = current.session.native
  active(current)
  local samples = fixture.signal(512)
  buffer.writef32(samples, 0, 0 / 0)
  native.pushAudio(SYSTEM, samples)
  current.advance()
  expect.equal(reader:snapshot().gapReason, 'invalidSamples', 'non-finite PCM is an expected explicit gap')
  expect.equal(reader:snapshot().state.kind, 'active', 'sample rejection does not change capture state')
  local realNew = require('../features').new
  require('../features').new = function()
    error 'fixture unexpected analyzer acquisition error'
  end
  expect.raises(function()
    current.observed.service:open(current.observed.context, SYSTEM, { size = 1024 })
  end, 'unexpected analyzer acquisition error')
  require('../features').new = realNew
  local previous = reader:snapshot()
  current.failures.feed = true
  push(current, 512)
  current.advance()
  local reports = native.events.reported
  expect.equal(#reports, 1, 'feed errors reach the protected frame boundary')
  expect.truthy(reports[1].message:find 'unexpected feed error', 'the original DSP failure is retained')
  expect.equal(reader:snapshot(), previous, 'programming errors never publish an unavailable state')
  current.failures.feed = false
end)

test('provider_publishes_the_bounded_94_hop_list_after_a_warmed_carry', function()
  local current = fixture.new()
  local reader = fixture.open(current.observed, SYSTEM, { size = 512 })
  active(current)
  push(current, 511, 0)
  current.advance()
  push(current, 12000, 511)
  current.advance()
  local retained = reader:snapshot()
  expect.equal(#retained.hops, 94, 'all bounded complete hops remain available')
  expect.equal(retained.hops[1].endFrame, 512, 'the first carried window')
  expect.equal(retained.hops[94].endFrame, 512 + 93 * 128, 'the last complete hop')
  expect.equal(retained.latest.endFrame, retained.hops[94].endFrame, 'latest uses the last ordered hop')
  current.advance()
  expect.equal(#reader:snapshot().hops, 0, 'a later empty frame does not replay the bounded list')
  expect.equal(#retained.hops, 94, 'the bounded list survives later batch reuse')
end)

return test
