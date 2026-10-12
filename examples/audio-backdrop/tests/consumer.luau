local testing = require '@testing'
local meter = require '../meter'
local rawLevel = require '../raw-level'
local expect = testing.expect
local test = testing.suite()
local lunette = require '@lunette'
local SYSTEM: lunette.AudioSource = { kind = 'system' }
type BootSession = testing.Session & { native: testing.Native }

local function advance(session: BootSession)
  session.native.advanceFrame()
  session:update()
end

local function text(session: BootSession): string
  session.native.events.draw = {}
  session:draw()
  for _, call in session.native.events.draw do
    if call[1] == 'text' then
      return call[2]
    end
  end
  error 'the meter did not draw'
end

local function tone(frames: number): { number }
  local samples = {}
  for index = 0, frames - 1 do
    local value = 0.5 * math.sin(2 * math.pi * 750 * index / 48000)
    samples[#samples + 1] = value
    samples[#samples + 1] = -value
  end
  return samples
end

test('the independent consumer uses real audio providers without any backdrop entry', function()
  local session = testing.boot { 'frame', 'audio', 'audio-analysis' }
  local consumer = session:use(meter.definition)
  local events = session.native.events
  expect.equal(events.audioOpened, 1, 'raw and feature readers share native capture')
  session.native.setAudioState(SYSTEM, { kind = 'active', provenance = 'pipewire-client' })
  session.native.pushAudio(SYSTEM, tone(2048), { generation = 2, sequence = 1 })
  advance(session)
  local shown = text(session)
  expect.truthy(shown:find('Audio meter: active', 1, true), 'raw reader state')
  expect.truthy(shown:find('raw peak 0.500', 1, true), 'raw samples cross the public copy boundary')
  expect.truthy(shown:find('RMS 0.354', 1, true), 'stereo energy survives phase inversion')
  expect.truthy(shown:find('1 new hops', 1, true), 'analysis publishes a completed window')
  expect.equal(events.audioSnapshots, 1, 'one poll for raw and feature consumption')
  advance(session)
  expect.truthy(text(session):find('0 new hops', 1, true), 'an empty publication does not replay a hop')
  session.native.setAudioState(SYSTEM, { kind = 'unavailable', reason = 'no-server', detail = 'fixture outage' })
  advance(session)
  local unavailable = text(session)
  expect.truthy(unavailable:find('Analysis: unavailable', 1, true), 'loss clears analysis features')
  expect.falsy(unavailable:find('RMS ', 1, true), 'loss does not display old RMS values')
  session.native.setAudioState(SYSTEM, { kind = 'active', provenance = 'pipewire-client' })
  advance(session)
  local recovering = text(session)
  expect.truthy(recovering:find('Analysis: active', 1, true), 'recovery waits for a fresh complete window')
  expect.falsy(recovering:find('RMS ', 1, true), 'active recovery without a new hop does not display old RMS values')
  consumer:disable()
  expect.equal(events.audioClosed, 1, 'consumer cleanup releases the last reader')
end)

test('provider interruption closes and reacquires only the independent consumer resources', function()
  local session = testing.boot { 'frame', 'audio', 'audio-analysis' }
  local consumer = session:use(meter.definition)
  session.instances.audio:disable()
  expect.equal(session.native.events.audioClosed, 1, 'audio outage closes shared source')
  session.instances.audio:enable()
  expect.equal(session.native.events.audioOpened, 2, 'provider recovery shares a fresh source')
  consumer:disable()
  expect.equal(session.native.events.audioClosed, 2, 'recovered source closes')
  consumer:enable()
  expect.equal(session.native.events.audioOpened, 3, 'reactivation creates no duplicate reader')
  session:close()
  expect.equal(session.native.events.audioClosed, 3, 'session shutdown releases capture')
end)

test('raw sampling is bounded and does not mutate a retained publication', function()
  local session = testing.boot { 'frame', 'audio' }
  local observed = session:observe(require('@lunette-contracts/audio').capability)
  local reader = observed.service:open(observed.context, SYSTEM)
  session.native.setAudioState(SYSTEM, { kind = 'active' })
  session.native.pushAudio(SYSTEM, tone(1024), { sequence = 8, generation = 3 })
  advance(session)
  local publication = reader:snapshot()
  local result = rawLevel.read(publication)
  expect.equal(result.frames, 256, 'bounded raw sample work')
  expect.equal(result.sequence, 8, 'block identity is preserved')
  expect.equal(result.generation, 3, 'stream identity is preserved')
  expect.near(result.peak, 0.5, 0.00001, 'generated tone peak')
  local copied = publication.blocks[1]:copySamples()
  buffer.writef32(copied, 0, 99)
  expect.near(rawLevel.read(publication).peak, 0.5, 0.00001, 'another copy stays independent')
end)

return test
