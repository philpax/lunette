local testing = require '@testing'
local expect = testing.expect
local support = require './support/response'
local analysis = require '@lunette-contracts/audio-analysis'
local audio = require '@lunette-contracts/audio'
local plugin = require '@lunette-plugin'

local test = testing.suite()
local SYSTEM = { kind = 'system' }

test('hidden readers release and reacquire before visibility returns without replaying retained onsets', function()
  local env = support.boot()
  env.update(0.1, true)
  expect.equal(select(2, env.counts()), 0, 'initial hidden has no reader')
  env.publish(SYSTEM, 1, 4096, { support.hop(1, 4096, 1) })
  env.update(0.1, false)
  expect.equal(select(2, env.counts()), 1, 'reader reacquired on first false primary sample')
  expect.equal(#env.model.waves, 0, 'retained open publication is not replayed')
  env.publish(SYSTEM, 1, 4608, { support.hop(1, 4608, 1) })
  env.update(0.1, false)
  expect.equal(#env.model.waves, 1, 'new onset delivered')
  local service = env.session:observe(analysis.capability)
  local external = service.service:open(service.context, SYSTEM)
  expect.equal(external.kind, 'success', 'independent consumer open')
  env.update(0.8, true)
  expect.equal(select(2, env.counts()), 1, 'fully hidden releases only the backdrop reader')
  env.update(0.01, true)
  expect.equal(select(2, env.counts()), 1, 'hidden backdrop leaves the independent reader live')
  env.update(0.01, false)
  expect.equal(select(2, env.counts()), 2, 'reacquired before fade-in alongside the independent reader')
  expect.equal(#env.model.waves, 1, 'reacquire does not replay old publication')
  env.factory.controls.setEnabled(false)
  env.update(0.001, false)
  expect.equal(select(2, env.counts()), 2, 'disable preserves the backdrop reader during fade')
  env.update(0.8, false)
  expect.equal(select(2, env.counts()), 1, 'disabled backdrop leaves the independent reader live')
  external.reader:close()
  expect.equal(select(2, env.counts()), 0, 'independent consumer closes its own reader')
  env.session:close()
end)

test('every new hop is delivered once with cumulative sample age and empty native frames never replay', function()
  local env = support.boot()
  env.update(1.2, false)
  -- Hops are far enough apart to be separate transients rather than one transient split across hops.
  env.publish(SYSTEM, 1, 12000, {
    support.hop(1, 8000, 0.5),
    support.hop(1, 10000, 0.6),
    support.hop(1, 12000, 0.7),
  })
  env.update(0, false)
  expect.equal(#env.model.waves, 3, 'all completed hop onsets delivered')
  expect.near(env.model.waves[1].age, 4000 / 48000, 1e-8, 'first hop sample age')
  expect.near(env.model.waves[2].age, 2000 / 48000, 1e-8, 'second hop sample age')
  expect.equal(env.model.waves[3].age, 0, 'latest ending')
  env.update(0, false)
  expect.equal(#env.model.waves, 3, 'same publication deduplicated')
  env.publish(SYSTEM, 1, 12000, {})
  env.update(0, false)
  expect.equal(#env.model.waves, 3, 'empty publication never replays latest onset')
  env.publish(SYSTEM, 1, 15000, { support.hop(1, 13500, 1) })
  env.update(0, false)
  expect.near(env.model.waves[4].age, 1500 / 48000, 1e-8, 'PCM after last completed hop contributes to age')
  env.session:close()
end)

test('generation resets clear old waves and repeated gap publications do not clear new waves', function()
  local env = support.boot()
  env.update(1.2, false)
  env.publish(SYSTEM, 1, 4096, { support.hop(1, 4096, 0.5) })
  env.update(0, false)
  expect.equal(#env.model.waves, 1, 'first generation onset')
  env.publish(SYSTEM, 2, 2048, { support.hop(1, 8192, 1), support.hop(2, 2048, 0.75) })
  env.update(0, false)
  expect.equal(#env.model.waves, 1, 'generation change clears previous impulse history')
  expect.equal(env.model.onsetGap, 'publication', 'generation reset is an explicit gap')
  expect.equal(env.model.waves[1].strength, 0.75, 'new generation onset survives reset')
  env.update(0, false)
  expect.equal(#env.model.waves, 1, 'repeated generation publication preserves the new onset')
  env.publish(SYSTEM, 2, 2560, { support.hop(2, 2560, 1) }, nil, nil, true)
  env.update(0, false)
  expect.equal(#env.model.waves, 1, 'publication gap clears previous impulse history')
  expect.equal(env.model.waves[1].strength, 1, 'gap publication onset survives reset')
  env.update(0, false)
  expect.equal(#env.model.waves, 1, 'repeated gap publication preserves the new onset')
  env.session:close()
end)

test('source changes crossfade bounded targets and own no more than two readers', function()
  local env = support.boot()
  env.update(1.2, false)
  env.publish(SYSTEM, 1, 4096, {}, { 0.0625, 0, 0 }, nil, nil, { 1, 0, 0, 0, 0, 0, 0, 0 })
  env.update(1, false)
  local process = env.native.newProcess(301)
  local source = { kind = 'process', process = process }
  env.publish(source, 1, 4096, {}, { 0, 0, 0.0625 }, nil, nil, { 0, 0, 0, 0, 0, 0, 0, 1 })
  env.factory.choice:pin(process)
  env.update(0.6, false)
  expect.equal(select(2, env.counts()), 2, 'incoming and outgoing readers coexist')
  expect.near(env.model.target.bass, 0.25, 1e-8, 'bass target crossfade midpoint')
  expect.near(env.model.target.treble, 0.25, 1e-8, 'treble target crossfade midpoint')
  expect.near(env.model.target.spectrum[1], 4 / 9, 1e-8, 'outgoing low spectrum band fades halfway')
  expect.near(env.model.target.spectrum[8], 13 / 28, 1e-8, 'incoming high spectrum band fades halfway')
  env.update(0.6, false)
  expect.equal(select(2, env.counts()), 1, 'outgoing reader released at crossfade end')
  expect.equal(env.model.target.bass, 0, 'new bass reached')
  expect.equal(env.model.target.treble, 0.5, 'new treble reached')
  env.session:close()
  expect.equal(select(2, env.counts()), 0, 'all owner readers released')
end)

test('starting idle and unavailable incoming sources crossfade outgoing features toward zero', function()
  for _, audioState in
    {
      { kind = 'starting' },
      { kind = 'idle' },
      { kind = 'unavailable', reason = 'unresolved-attribution', detail = 'no stream' },
    }
  do
    local env = support.boot()
    env.update(1.2, false)
    env.publish(SYSTEM, 1, 4096, {}, { 0.0625, 0, 0 })
    env.update(0, false)
    local process = env.native.newProcess(311)
    local source = { kind = 'process', process = process }
    env.publish(source, 1, 4096, {}, { 0, 0, 0.0625 }, audioState)
    env.factory.choice:pin(process)
    env.update(0, false)
    expect.equal(env.model.target.bass, 0.5, audioState.kind .. ' begins from outgoing target')
    expect.equal(env.model.settling, false, audioState.kind .. ' uses the source transition')
    env.update(0.6, false)
    expect.near(env.model.target.bass, 0.25, 1e-8, audioState.kind .. ' source transition midpoint')
    expect.equal(env.model.target.treble, 0, audioState.kind .. ' retained unavailable features ignored')
    env.update(0.6, false)
    expect.equal(env.model.target.bass, 0, audioState.kind .. ' source transition reaches zero')
    expect.equal(select(2, env.counts()), 1, audioState.kind .. ' closes outgoing reader')
    env.session:close()
  end
end)

test('three rapid source changes preserve the blended target at each zero-time reversal', function()
  local env = support.boot()
  env.update(1.2, false)
  env.publish(SYSTEM, 1, 4096, {}, { 0.0625, 0, 0 })
  env.update(0, false)
  local first = env.native.newProcess(321)
  env.publish({ kind = 'process', process = first }, 1, 4096, {}, { 0, 0, 0.0625 })
  env.factory.choice:pin(first)
  env.update(0.3, false)
  expect.near(env.model.target.bass, 0.375, 1e-8, 'first blended bass')
  expect.near(env.model.target.treble, 0.125, 1e-8, 'first blended treble')
  for index = 2, 4 do
    local before = env.model.target
    local process = env.native.newProcess(320 + index)
    env.publish({ kind = 'process', process = process }, 1, 4096, {}, { 0, 0.0625, 0 })
    env.factory.choice:pin(process)
    env.update(0, false)
    expect.near(env.model.target.bass, before.bass, 1e-8, 'switch ' .. index .. ' keeps blended bass')
    expect.near(env.model.target.mid, before.mid, 1e-8, 'switch ' .. index .. ' keeps blended mid')
    expect.near(env.model.target.treble, before.treble, 1e-8, 'switch ' .. index .. ' keeps blended treble')
    env.update(0.12, false)
    expect.near(env.model.target.bass, before.bass * 0.9, 1e-8, 'switch ' .. index .. ' progresses continuously')
    expect.equal(select(2, env.counts()), 2, 'only incoming and outgoing readers remain')
  end
  expect.equal(select(3, env.counts()), 2, 'rapid switches never open a third reader')
  env.session:close()
end)

test('raw process status stays independent of analysis and never opens raw readers', function()
  local env = support.boot()
  local process = env.native.newProcess(331)
  local statuses =
    { { process = process, label = 'application', state = { kind = 'active', provenance = 'pipewire-client' } } }
  local rawOpens = 0
  env.session:use(plugin.provider({
    name = 'testing/raw-status',
    capability = audio.capability,
    build = function(): audio.Service
      return {
        processes = function(): { audio.ProcessStatus }
          return statuses
        end,
        open = function()
          rawOpens += 1
          error 'status discovery must not open a raw reader'
        end,
      }
    end,
  }).definition)
  env.session.runtime:drain()
  env.update(0.1, true)
  expect.equal(env.factory.choice.processStatuses, statuses, 'raw status is available while hidden')
  expect.equal(rawOpens, 0, 'no hidden raw reader')
  statuses = { { process = process, label = 'application', state = { kind = 'idle' } } }
  env.update(0.1, false)
  expect.equal(env.factory.choice.processStatuses[1].state.kind, 'idle', 'raw status updates independently')
  expect.equal(rawOpens, 0, 'discovery never requested raw PCM')
  env.session:close()
end)

test('logical process identity does not reopen and unavailable application never falls back to system', function()
  local env = support.boot()
  local process = env.native.newProcess(401)
  env.factory.choice:pin(process)
  env.update(0.1, false)
  local opened = env.counts()
  env.factory.choice:pin { id = process.id, dead = false }
  env.update(0.1, false)
  expect.equal(env.counts(), opened, 'logical process id retains one source')
  local source = { kind = 'process', process = process }
  env.publish(
    source,
    1,
    4096,
    {},
    nil,
    { kind = 'unavailable', reason = 'unresolved-attribution', detail = 'no match' }
  )
  env.update(1.5, false)
  expect.equal(env.factory.controls.source().kind, 'process', 'unavailable application remains selected')
  expect.equal(env.readers[#env.readers].source.kind, 'process', 'no system fallback reader')
  env.session:close()
end)

return test
