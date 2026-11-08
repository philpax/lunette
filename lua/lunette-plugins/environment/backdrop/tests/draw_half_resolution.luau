local testing = require '@testing'
local render = require '@testing/render'
local fixture = require './support/half-resolution'
local expect = testing.expect
local test = testing.suite()

local function prepared(recorder: render.Recorder, count: number): ()
  local computes, drew = 0, false
  for _, call in recorder.calls do
    if call[1] == 'compute' then
      expect.equal(drew, false, 'prerequisite fields precede consuming draws')
      computes += 1
    elseif call.draw then
      drew = true
    end
  end
  expect.equal(computes, count, 'the pass prepares both fields when needed')
end

for _, miniatureFirst in { false, true } do
  test((if miniatureFirst then 'miniature' else 'scene') .. ' first respects prerequisite submission order', function()
    local env = fixture.boot(true)
    local value = fixture.frame(env)
    local checkpoint = fixture.seedState(env)
    if miniatureFirst then
      env.renderer.miniature(env.pass, value, 0.5, nil, 0.7)
      prepared(env.recorder, 2)
    end
    local target = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
    prepared(target.recorder, 2)
    if not miniatureFirst then
      expect.equal(#fixture.calls(env.recorder, 'compute'), 0, 'the main pass depends on prerequisite fields')
      local composite = fixture.calls(env.recorder, 'mesh')
      expect.equal(#composite, 1, 'one composite samples the curtain target')
      expect.equal(composite[1].state.setBlendMode[2], 'premultiplied', 'the composite preserves premultiplied colour')
      env.renderer.miniature(env.pass, value, 0.5, nil, 0.7)
      expect.equal(#fixture.calls(env.recorder, 'compute'), 0, 'the miniature reuses the earlier prerequisite')
    end
    env.recorder:assertRestored(checkpoint)
    table.clear(target.recorder.calls)
    local repeated = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
    expect.equal(repeated, target, 'the owned target is reused')
    expect.equal(#fixture.calls(target.recorder, 'reset'), 1, 'each prerequisite recording resets its pass')
    prepared(target.recorder, 2)
    local fresh = fixture.frame(env)
    fresh.waves[2].position = 0.23
    table.clear(target.recorder.calls)
    fixture.preparation(env.renderer.render(env.pass, fresh, vector.zero))
    prepared(target.recorder, 2)
    local position
    for _, call in fixture.calls(target.recorder, 'send') do
      if call[2] == 'backdropWaves' then
        position = call[3][1][3]
      end
    end
    expect.equal(position, 0.23, 'a fresh Frame at the same clock uploads its changed waves')
    fixture.close(env)
  end)
end

test('target reuse, failed resize, and successful replacement preserve resource ownership', function()
  local env = fixture.boot(true)
  local target = fixture.preparation(env.renderer.render(env.pass, fixture.frame(env), vector.zero))
  local texture = target:getCanvas()[1]
  expect.equal(texture.layers, 2, 'the target has one layer per eye')
  local count = #env.recorder.textureAcquisitions
  env.recorder.width, env.recorder.height = 1200, 800
  expect.equal(
    fixture.preparation(env.renderer.render(env.pass, fixture.frame(env), vector.zero)),
    target,
    'same-size targets reuse their pass'
  )
  expect.equal(#env.recorder.textureAcquisitions, count, 'same-size reuse allocates nothing')
  env.recorder.width, env.recorder.height = 1921, 1281
  env.recorder.passFailure = 'injected resize failure'
  local checkpoint = fixture.seedState(env)
  expect.raises(function()
    env.renderer.render(env.pass, fixture.frame(env), vector.zero)
  end, 'injected resize failure')
  env.recorder:assertRestored(checkpoint)
  expect.equal(target.released, false, 'failed replacement retains the old pass')
  expect.equal(texture.released, false, 'failed replacement retains the old texture')
  expect.equal(
    env.recorder.textureAcquisitions[#env.recorder.textureAcquisitions].released,
    true,
    'the partial replacement is released'
  )
  env.recorder.width, env.recorder.height = 960, 640
  expect.equal(
    fixture.preparation(env.renderer.render(env.pass, fixture.frame(env), vector.zero)),
    target,
    'the previous target remains usable'
  )
  env.recorder.width, env.recorder.height = 1921, 1281
  local replacement = fixture.preparation(env.renderer.render(env.pass, fixture.frame(env), vector.zero))
  expect.equal(replacement:getCanvas()[1].width, 961, 'an odd final column is retained')
  expect.equal(replacement:getCanvas()[1].height, 641, 'an odd final row is retained')
  expect.equal(texture.released, true, 'successful replacement releases the old texture')
  fixture.close(env)
  local mainCalls, targetCalls = #env.recorder.calls, #replacement.recorder.calls
  expect.equal(env.renderer.render(env.pass, fixture.frame(env), vector.zero), nil, 'shutdown returns no prerequisite')
  env.renderer.miniature(env.pass, fixture.frame(env), 0.5, nil, 1)
  expect.equal(#env.recorder.calls, mainCalls, 'shutdown records no main commands')
  expect.equal(#replacement.recorder.calls, targetCalls, 'shutdown never touches the released target')
  expect.equal(replacement.released, true, 'shutdown releases the replacement pass')
end)

test('prerequisite failure restores the caller state', function()
  local env = fixture.boot(true)
  local value = fixture.frame(env)
  local target = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
  local checkpoint = fixture.seedState(env)
  local original = target.draw
  target.draw = function()
    error('injected prerequisite failure', 0)
  end
  expect.raises(function()
    env.renderer.render(env.pass, value, vector.zero)
  end, 'injected prerequisite failure')
  target.draw = original
  env.recorder:assertRestored(checkpoint)
  fixture.close(env)
end)

test('small scenes and diagnostic views retain direct drawing', function()
  local env = fixture.boot()
  expect.equal(
    env.renderer.render(env.pass, fixture.frame(env), vector.zero),
    nil,
    'a small scene needs no prerequisite'
  )
  env.recorder.width, env.diagnostic = 960, 'field'
  table.clear(env.recorder.calls)
  expect.equal(
    env.renderer.render(env.pass, fixture.frame(env), vector.zero),
    nil,
    'a diagnostic needs no prerequisite'
  )
  expect.equal(#env.recorder.passAcquisitions, 0, 'neither path allocates a curtain pass')
  fixture.close(env)
end)

return test
