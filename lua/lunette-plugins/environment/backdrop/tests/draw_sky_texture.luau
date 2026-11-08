local testing = require '@testing'
local render = require '@testing/render'
local fixture = require './support/half-resolution'
local shader = require '../private/rendering/shader'
local expect = testing.expect
local test = testing.suite()

local function fields(recorder: render.Recorder, sky: number, onset: number): ()
  local current, counts, drew = nil, {}, false
  for _, call in recorder.calls do
    if call[1] == 'setShader' then
      current = call[2]
    elseif call[1] == 'compute' then
      expect.equal(drew, false, 'field updates precede consuming draws')
      counts[current.compute] = (counts[current.compute] or 0) + 1
    elseif call.draw then
      drew = true
    end
  end
  expect.equal(counts[shader.skyCompute] or 0, sky, 'the sky refreshes only when needed')
  expect.equal(counts[shader.curtainCompute] or 0, onset, 'only dense onsets need a field')
end

for _, miniatureFirst in { false, true } do
  test(
    (if miniatureFirst then 'miniature' else 'scene') .. ' first shares fields and refreshes fresh Frames',
    function()
      local env = fixture.boot()
      local checkpoint = fixture.seedState(env)
      for _, count in { 9, 9, 8, 0, 9 } do
        local value = fixture.frame(env, count)
        table.clear(env.recorder.calls)
        if miniatureFirst then
          env.renderer.miniature(env.pass, value, 0.5, nil, 0.7)
          env.renderer.render(env.pass, value, vector.zero)
        else
          env.renderer.render(env.pass, value, vector.zero)
          env.renderer.miniature(env.pass, value, 0.5, nil, 0.7)
        end
        env.renderer.render(env.pass, value, vector.zero)
        fields(env.recorder, 1, if count > 8 then 1 else 0)
        expect.equal(#fixture.calls(env.recorder, 'draw'), 15, 'sharing retains direct scene geometry')
        env.recorder:assertRestored(checkpoint)
      end
      expect.equal(#env.recorder.textureAcquisitions, 3, 'fresh Frames and sparse transitions reuse textures')
      fixture.close(env)
    end
  )
end

test('diagnostic, skipped, and dark draws leave the same Frame available for preparation', function()
  local env = fixture.boot()
  local value = fixture.frame(env)
  value.visibility = 0
  env.renderer.render(env.pass, value, vector.zero)
  env.renderer.miniature(env.pass, value, 0.5, nil, 0)
  expect.equal(#env.recorder.textureAcquisitions, 0, 'skipped draws acquire nothing')
  value.visibility, value.brightness = 1, 0
  env.renderer.render(env.pass, value, vector.zero)
  expect.equal(#fixture.calls(env.recorder, 'compute'), 0, 'dark fields are not computed')
  value.brightness, env.diagnostic = 0.8, 'field'
  env.renderer.render(env.pass, value, vector.zero)
  expect.equal(#fixture.calls(env.recorder, 'compute'), 0, 'diagnostics do not compute fields')
  table.clear(env.recorder.calls)
  env.renderer.miniature(env.pass, value, 0.5, nil, 1)
  env.diagnostic = 'none'
  env.renderer.render(env.pass, value, vector.zero)
  fields(env.recorder, 1, 1)
  fixture.close(env)
end)

test('an onset recording failure restores state and retries without repeating the sky', function()
  local env = fixture.boot()
  local value = fixture.frame(env)
  local checkpoint = fixture.seedState(env)
  local original = env.pass.compute
  env.pass.compute = function(self: render.Pass, x: number, ...: number)
    if x == 64 then
      error('injected onset failure', 0)
    end
    original(self, x, ...)
  end
  expect.raises(function()
    env.renderer.render(env.pass, value, vector.zero)
  end, 'injected onset failure')
  env.pass.compute = original
  env.recorder:assertRestored(checkpoint)
  expect.equal(#fixture.calls(env.recorder, 'draw'), 0, 'unprepared fields are never drawn')
  fields(env.recorder, 1, 0)
  table.clear(env.recorder.calls)
  env.renderer.miniature(env.pass, value, 0.5, nil, 1)
  fields(env.recorder, 0, 1)
  env.recorder:assertRestored(checkpoint)
  fixture.close(env)
end)

test('a draw failure preserves successful fields for another view of the same Frame', function()
  local env = fixture.boot()
  local value = fixture.frame(env)
  local checkpoint = fixture.seedState(env)
  local original = env.pass.draw
  env.pass.draw = function()
    error('injected draw failure', 0)
  end
  expect.raises(function()
    env.renderer.render(env.pass, value, vector.zero)
  end, 'injected draw failure')
  env.pass.draw = original
  fields(env.recorder, 1, 1)
  env.recorder:assertRestored(checkpoint)
  table.clear(env.recorder.calls)
  env.renderer.miniature(env.pass, value, 0.5, nil, 1)
  fields(env.recorder, 0, 0)
  fixture.close(env)
end)

test('sampler acquisition failure releases partial fields and permits a complete retry', function()
  local env = fixture.boot()
  local value = fixture.frame(env)
  local checkpoint = fixture.seedState(env)
  env.recorder.samplerFailure = 'injected sampler failure'
  expect.raises(function()
    env.renderer.render(env.pass, value, vector.zero)
  end, 'injected sampler failure')
  env.recorder:assertRestored(checkpoint)
  env.recorder:assertResourcesReleased()
  expect.equal(#fixture.calls(env.recorder, 'compute'), 0, 'failed acquisition records no work')
  env.renderer.render(env.pass, value, vector.zero)
  fields(env.recorder, 1, 1)
  fixture.close(env)
end)

return test
