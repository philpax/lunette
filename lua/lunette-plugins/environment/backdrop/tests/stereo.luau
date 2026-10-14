local testing = require '@testing'
local expect = testing.expect
local support = require './support/response'
local config = require '../config'
local model = require '../private/rendering/model'
local analysis = require '@lunette-contracts/audio-analysis'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/session/frame'
local capture = require '@lunette-plugins/audio/capture'
local audioAnalysis = require '@lunette-plugins/audio/analysis'
local backdrop = require '../'

local test = testing.suite()
local SYSTEM = { kind = 'system' }

local function offset(position: number): number
  return (position - 0.5 + 0.5) % 1 - 0.5
end

local function sided(left: { number }, right: { number }, ending: number): analysis.Hop
  local hop = table.clone(support.hop(1, ending, 1, 'bass'))
  hop.trebleOnset = 1
  hop.leftSpectrum, hop.rightSpectrum = left, right
  for index = 1, 8 do
    hop.spectrum[index] = left[index] / 2 + right[index] / 2
  end
  return hop
end

test('simultaneous left bass and right treble place independent fixed onsets', function()
  local env = support.boot()
  env.update(1.2, false)
  local left = { 0.1, 0, 0, 0, 0, 0, 0, 0 }
  local right = { 0, 0, 0, 0, 0, 0, 0, 0.1 }
  env.publish(SYSTEM, 1, 4096, { sided(left, right, 4096) }, nil, nil, nil, nil, left, right)
  env.update(0, false)
  local bass, treble = env.model.waves[1], env.model.waves[2]
  expect.equal(bass.band, 'bass', 'first band')
  expect.truthy(offset(bass.position) > 0.09, 'left bass is to the viewer left')
  expect.truthy(offset(treble.position) < -0.09, 'right treble is to the viewer right')
  expect.equal(bass.frequency, 0, 'deep bass detail')
  expect.equal(treble.frequency, 1, 'upper treble detail')
  expect.truthy(env.model.target.stereo[1] < 0, 'sustained bass is left')
  expect.truthy(env.model.target.stereo[8] > 0, 'sustained treble is right')
  local position = bass.position
  env.native.events.headPose = lovr.math.newMat4():rotate(math.pi / 2, 0, 1, 0)
  env.update(0.1, false)
  expect.equal(bass.position, position, 'an existing event stays at its origin after a head turn')
  env.session:draw()
  expect.near(env.uniforms.backdropFacing[1], 0.75, 1e-8, 'sustained response follows the current facing')
  local stereo = env.uniforms.backdropStereo
  expect.truthy(stereo[1][1] < 0 and stereo[2][4] > 0, 'channel differences reach the shader')
  local details = env.uniforms.backdropWaveDetail
  expect.equal(details[1][1], 0, 'deep frequency reaches the shader')
  expect.equal(details[2][1], 1, 'upper frequency reaches the shader')
  env.session:close()
end)

test('centred energy stays neutral and changing sides never exceeds band strength', function()
  local state = model.new(config.schema.parse { response = 0.5 })
  local spectrum = { 1, 0.5, 0, 0, 0, 0, 0, 1 }
  for _, sign in { -1, 1, 0, -1, 0 } do
    state:setFeatures {
      bass = 1,
      mid = 0,
      treble = 1,
      spectrum = spectrum,
      stereo = { sign, sign, math.huge, 0 / 0, 0, 0, 0, sign },
    }
    for _ = 1, 20 do
      local frame = state:update(0.05, false)
      for band = 1, 8 do
        expect.truthy(math.abs(frame.stereo[band]) <= frame.spectrum[band], 'stereo remains bounded by energy')
      end
    end
  end
  state:noAudio()
  state:update(1.5, false)
  local frame = state:update(0, false)
  for band = 1, 8 do
    expect.equal(frame.stereo[band], 0, 'audio loss clears stereo along with energy')
  end
end)

test('loud passages retain strength differences without changing silence', function()
  local env = support.boot()
  env.update(1.2, false)
  local previous, previousSpectrum = 0, 0
  for _, value in { 0, 0.0001, 0.01, 0.0625, 0.25, 1, 4 } do
    env.publish(SYSTEM, 1, 4096, {}, { value, 0, 0 }, nil, nil, { value, 0, 0, 0, 0, 0, 0, 0 })
    env.update(0, false)
    local target = env.model.target
    if value == 0 then
      expect.equal(target.bass, 0, 'silence remains exactly zero')
      expect.equal(target.spectrum[1], 0, 'silent spectrum stays zero')
    else
      expect.truthy(target.bass > previous and target.bass < 1, 'louder input remains distinguishable and bounded')
      expect.truthy(target.spectrum[1] > previousSpectrum and target.spectrum[1] < 1, 'spectral detail keeps headroom')
    end
    previous, previousSpectrum = target.bass, target.spectrum[1]
  end
  env.session:close()
end)

test('stereo targets crossfade with energy across sources and unavailable input', function()
  local env = support.boot()
  env.update(1.2, false)
  local lit = { 0.1, 0, 0, 0, 0, 0, 0, 0 }
  local zero = table.create(8, 0)
  env.publish(SYSTEM, 1, 4096, {}, nil, nil, nil, nil, lit, zero)
  env.update(0, false)
  local strength = env.model.target.spectrum[1]
  expect.equal(env.model.target.stereo[1], -strength, 'hard left target')
  local process = env.native.newProcess(410)
  local source = { kind = 'process', process = process }
  env.publish(source, 1, 4096, {}, nil, nil, nil, nil, zero, lit)
  env.factory.choice:pin(process)
  env.update(0.6, false)
  expect.near(env.model.target.stereo[1], 0, 1e-12, 'channel difference passes through centre')
  expect.near(env.model.target.spectrum[1], strength, 1e-12, 'equal source energy does not dip')
  env.update(0.6, false)
  expect.equal(env.model.target.stereo[1], strength, 'hard right target')
  env.publish(source, 1, 4096, {}, nil, { kind = 'idle' }, nil, nil, zero, lit)
  env.update(0, false)
  env.update(1.5, false)
  expect.equal(env.model.response.stereo[1], 0, 'unavailable input settles to zero')
  env.session:close()
end)

test('centred onsets and extreme finite powers preserve valid detail', function()
  for _, scale in { 0.1, 1e308 } do
    local env = support.boot()
    env.update(1.2, false)
    local both = { scale, scale, scale, 0, 0, 0, 0, 0 }
    env.publish(SYSTEM, 1, 4096, { sided(both, both, 4096) }, nil, nil, nil, both, both, both)
    env.update(0, false)
    local wave = env.model.waves[1]
    expect.truthy(math.abs(offset(wave.position)) <= 0.025, 'centred bass remains within its scatter')
    expect.near(wave.frequency, 0.5, 1e-12, 'frequency centroid remains finite')
    expect.equal(env.model.target.stereo[1], 0, 'equal channels have no signed energy')
    env.session:close()
  end
end)

test('stereo PCM with separate low and high tones reaches distinct visual targets', function()
  local state
  local factory = backdrop.create({}, function(_context: plugin.Context, current: model.State)
    state = current
  end)
  local session = testing.boot {
    { id = 'frame', definition = frame.definition },
    { id = 'audio', definition = capture.definition },
    { id = 'audio-analysis', definition = audioAnalysis.definition },
    { id = 'desktop/backdrop', definition = factory.definition },
  }
  local native = session.native
  native.events.mainSessionVisible = false
  native.advanceFrame()
  session:update(1.2)
  assert(state, 'backdrop model initialized')
  local observed = session:observe(analysis.capability)
  local result = observed.service:open(observed.context, SYSTEM)
  expect.equal(result.kind, 'success', result.detail)
  local reader = result.reader
  local size = 2048
  expect.equal(reader.profile.size, size, 'the observer shares the backdrop analysis profile')
  native.setAudioState(SYSTEM, { kind = 'active', provenance = 'pipewire-client' })
  native.pushAudio(SYSTEM, buffer.create(size * 8), { generation = 1, sequence = 1, startFrame = 0 })
  native.advanceFrame()
  session:update(0)
  expect.equal(reader:snapshot().endFrame, size, 'the silent PCM block establishes the analysis baseline')
  expect.equal(#reader:snapshot().hops, 1, 'the silent baseline publishes one complete window')
  local samples = buffer.create(size * 8)
  for frame = 0, size - 1 do
    buffer.writef32(samples, frame * 8, 0.2 * math.sin(2 * math.pi * 4 * frame / size))
    buffer.writef32(samples, frame * 8 + 4, 0.2 * math.sin(2 * math.pi * 256 * frame / size))
  end
  native.pushAudio(SYSTEM, samples, { generation = 1, sequence = 2, startFrame = size })
  native.advanceFrame()
  session:update(0)
  local snapshot = reader:snapshot()
  expect.equal(snapshot.state.kind, 'active', 'native PCM reaches the active analysis publication')
  expect.equal(snapshot.generation, 1, 'the analysis publication retains the PCM generation')
  expect.equal(snapshot.endFrame, size * 2, 'the analysis publication advances through both PCM blocks')
  expect.truthy(#snapshot.hops > 0, 'the real analysis provider publishes completed tone windows')
  local bassOnset, trebleOnset = 0, 0
  for _, hop in snapshot.hops do
    bassOnset = math.max(bassOnset, hop.bassOnset)
    trebleOnset = math.max(trebleOnset, hop.trebleOnset)
  end
  expect.truthy(bassOnset > 0, 'the real analysis provider publishes the low transient')
  expect.truthy(trebleOnset > 0, 'the real analysis provider publishes the high transient')
  local latest = snapshot.latest
  expect.truthy(latest, 'the real analysis provider publishes steady tone powers')
  expect.truthy(latest.leftSpectrum[2] > latest.rightSpectrum[2], 'published low-band power is left-sided')
  expect.truthy(latest.rightSpectrum[8] > latest.leftSpectrum[8], 'published high-band power is right-sided')
  expect.truthy(state.target.stereo[2] < -0.1, '93.75 Hz tone drives left low-band activity')
  expect.truthy(state.target.stereo[8] > 0.1, '6 kHz tone drives right high-band activity')
  local bass, treble
  for _, wave in state.waves do
    if wave.band == 'bass' then
      bass = wave
    elseif wave.band == 'treble' then
      treble = wave
    end
  end
  expect.truthy(bass and offset(bass.position) > 0.09, 'a real low transient starts on the left')
  expect.truthy(treble and offset(treble.position) < -0.09, 'a real high transient starts on the right')
  native.advanceFrame()
  session:update(0.1)
  session:draw()
  local stereo
  for _, call in native.events.render.calls do
    if call[1] == 'send' and call[2] == 'backdropStereo' then
      stereo = call[3]
    end
  end
  expect.truthy(stereo, 'the PCM response reaches the stereo shader uniform')
  expect.truthy(stereo[1][2] < 0 and stereo[2][4] > 0, 'PCM channel differences reach distinct shader bands')
  session:close()
end)

return test
