local testing = require '@testing'
local render = require '@testing/render'
local fixture = require './support/half-resolution'
local expect = testing.expect
local test = testing.suite()

local function assertComputeBeforeDraw(recorder: render.Recorder, count: number): ()
  local computes, drew = 0, false
  for _, call in recorder.calls do
    if call[1] == 'compute' then
      expect.equal(drew, false, 'field updates precede every consuming draw in their pass')
      computes += 1
    elseif call.draw then
      drew = true
    end
  end
  expect.equal(computes, count, 'the pass contains the required field updates')
end

for _, samples in { 1, 4 } do
  test('large stereo ' .. samples .. 'x scenes route only curtains through a reduced-resolution pass', function(): ()
    local env = fixture.boot(samples)
    local checkpoint = fixture.seedState(env)
    local projections, poses = {}, {}
    for eye = 1, 2 do
      projections[eye] = lovr.math.newMat4():fov(0.7 + eye * 0.03, 0.9 - eye * 0.02, 0.8, 0.6, 0.07, 400)
      poses[eye] = lovr.math.newMat4():translate(eye * 0.064, 1.7, -0.4):rotate(eye * 0.07, 0, 1, 0)
      env.recorder.projections[eye], env.recorder.viewPoses[eye] = projections[eye], poses[eye]
    end
    local head = vector.pack(2, 1.5, -4)
    local target = fixture.preparation(env.renderer.render(env.pass, fixture.frame(env), head))
    expect.equal(target, env.recorder.passAcquisitions[1], 'the returned pass belongs to the renderer context')
    expect.equal(#env.recorder.passAcquisitions, 1, 'the scene owns one prerequisite pass')
    local canvas = target:getCanvas()
    local texture = canvas[1]
    expect.equal(texture.width, 720, 'the curtain target meets the minimum width')
    expect.equal(texture.height, 480, 'the curtain target meets the minimum height')
    expect.equal(texture.layers, 2, 'each eye has an independent array layer')
    expect.equal(texture.options.type, 'array', 'the composite samples a stereo array')
    expect.equal(texture.options.format, 'rgba16f', 'the target retains linear HDR curtain colour')
    expect.equal(texture.options.linear, true, 'the target stores linear values')
    expect.equal(texture.options.samples, 1, 'the prerequisite is not multisampled')
    expect.equal(texture.options.mipmaps, false, 'the prerequisite uses only its base level')
    expect.equal(table.concat(texture.options.usage, ','), 'render,sample', 'the target supports drawing and sampling')
    expect.equal(canvas.depth, false, 'curtains do not acquire a depth attachment')
    expect.equal(canvas.samples, 1, 'the pass has one sample regardless of the main pass')
    for eye = 1, 2 do
      local copied = lovr.math.newMat4()
      target:getProjection(eye, copied)
      fixture.matrix(copied, projections[eye], 'the asymmetric projection is copied exactly')
      target:getViewPose(eye, copied, false)
      fixture.matrix(copied, poses[eye], 'the pose is copied without inversion or another head offset')
    end
    local clear = fixture.calls(target.recorder, 'setClear')[1]
    for lane = 2, 5 do
      expect.equal(clear[lane], 0, 'the target clears to transparent black')
    end
    local mainDraws, curtainDraws = fixture.calls(env.recorder, 'draw'), fixture.calls(target.recorder, 'draw')
    expect.equal(#mainDraws, 2, 'the sky and wisps remain full resolution')
    expect.equal(#curtainDraws, 3, 'all three curtain layers draw into the prerequisite')
    local meshes = env.recorder.meshAcquisitions
    expect.equal(mainDraws[1][2], meshes[1], 'the main sky keeps its own geometry')
    expect.equal(mainDraws[2][2], meshes[3], 'the main wisps keep their own geometry')
    local translated = lovr.math.newMat4():translate(head)
    for _, call in mainDraws do
      fixture.matrix(call.transform, translated, 'main geometry is centered on the head once')
    end
    for _, call in curtainDraws do
      expect.equal(call[2], meshes[2], 'the prerequisite contains only curtain geometry')
      fixture.matrix(call.transform, translated, 'curtains are centered on the head once')
    end
    local composite = fixture.calls(env.recorder, 'mesh')
    expect.equal(#composite, 1, 'one fullscreen draw composites both eye layers')
    expect.equal(composite[1][2], 3, 'the composite uses a fullscreen triangle')
    expect.equal(composite[1].state.setDepthWrite[1], false, 'the composite does not write scene depth')
    expect.equal(composite[1].state.setBlendMode[1], 'alpha', 'the composite uses alpha blending')
    expect.equal(composite[1].state.setBlendMode[2], 'premultiplied', 'the composite preserves premultiplied colour')
    local order, boundTexture, boundSampler = {}, nil, nil
    for _, call in env.recorder.calls do
      if call[1] == 'draw' then
        table.insert(order, if call[2] == meshes[1] then 'sky' else 'wisps')
      elseif call[1] == 'mesh' then
        table.insert(order, 'composite')
      elseif call[1] == 'send' and call[2] == 'curtainTexture' then
        boundTexture = call[3]
      elseif call[1] == 'send' and call[2] == 'curtainSampler' then
        boundSampler = call[3]
      end
    end
    expect.equal(table.concat(order, ','), 'sky,composite,wisps', 'the full-resolution layers surround the composite')
    expect.equal(boundTexture, texture, 'the main pass samples its returned prerequisite target')
    expect.equal(boundSampler.options.filter, 'linear', 'the composite upsamples with linear filtering')
    expect.equal(boundSampler.options.wrap, 'clamp', 'the composite does not wrap across the image boundary')
    env.recorder:assertRestored(checkpoint)
    expect.equal(target.released, false, 'resources remain live until context shutdown')
    fixture.close(env)
    expect.equal(target.released, true, 'context shutdown releases the pass')
    expect.equal(texture.released, true, 'context shutdown releases the target')
  end)
end

for _, guard in { 'small', 'mono', 'three views', 'two samples', 'no canvas', 'diagnostic', 'unsupported format' } do
  test(guard .. ' scenes retain direct drawing without a half-resolution allocation', function(): ()
    local env = fixture.boot()
    if guard == 'small' then
      env.recorder.width, env.recorder.height = 640, 480
    elseif guard == 'mono' then
      env.recorder.viewCount = 1
    elseif guard == 'three views' then
      env.recorder.viewCount = 3
    elseif guard == 'two samples' then
      env.recorder.samples = 2
    elseif guard == 'no canvas' then
      env.recorder.canvas = nil
    elseif guard == 'diagnostic' then
      env.diagnostic = 'field'
    else
      env.recorder.formatSupported = false
    end
    local result = env.renderer.render(env.pass, fixture.frame(env), vector.zero)
    expect.equal(result, nil, 'the direct path has no prerequisites')
    expect.equal(#env.recorder.passAcquisitions, 0, 'the guard avoids pass allocation')
    expect.equal(#env.recorder.textureAcquisitions, 3, 'only the existing sky and onset fields are owned')
    expect.equal(
      #fixture.calls(env.recorder, 'draw'),
      if guard == 'diagnostic' then 1 else 5,
      'direct geometry remains'
    )
    expect.equal(#fixture.calls(env.recorder, 'mesh'), 0, 'the direct path has no composite')
    fixture.close(env)
  end)
end

for _, guard in { 'invisible', 'negative visibility', 'inactive', 'closed' } do
  test(guard .. ' scenes do not allocate or record any rendering', function(): ()
    local env = fixture.boot()
    local value = fixture.frame(env)
    if guard == 'invisible' then
      value.visibility = 0
    elseif guard == 'negative visibility' then
      value.visibility = -1
    elseif guard == 'inactive' then
      env.instance:disable()
    else
      env.session:close()
    end
    expect.equal(env.renderer.render(env.pass, value, vector.zero), nil, 'the scene is skipped')
    if guard == 'inactive' or guard == 'closed' then
      env.renderer.miniature(env.pass, value, 0.5, nil, 1)
    end
    expect.equal(#env.recorder.calls, 0, 'a skipped renderer does not touch its caller pass')
    expect.equal(#env.recorder.meshAcquisitions, 0, 'a skipped renderer acquires no geometry')
    expect.equal(#env.recorder.textureAcquisitions, 0, 'a skipped renderer acquires no textures')
    expect.equal(#env.recorder.passAcquisitions, 0, 'a skipped renderer acquires no pass')
    if guard ~= 'closed' then
      fixture.close(env)
    else
      env.recorder:assertResourcesReleased()
    end
  end)
end

for _, shape in
  {
    { 960, 960, 720, 720 },
    { 1440, 640, 1080, 480 },
    { 960, 1280, 720, 960 },
    { 1440, 960, 720, 480 },
    { 1920, 1280, 960, 640 },
  }
do
  test(
    string.format('%dx%d scenes use a %dx%d reduced-resolution minimum target', shape[1], shape[2], shape[3], shape[4]),
    function(): ()
      local env = fixture.boot()
      env.recorder.width, env.recorder.height = shape[1], shape[2]
      local target = fixture.preparation(env.renderer.render(env.pass, fixture.frame(env), vector.zero))
      local texture = target:getCanvas()[1]
      expect.equal(texture.width, shape[3], 'the target width matches its selected minimum scale')
      expect.equal(texture.height, shape[4], 'the target height preserves the main aspect ratio')
      fixture.close(env)
    end
  )
end

test('the reduced-resolution target is reused across main sizes that map to the same dimensions', function(): ()
  local env = fixture.boot()
  local value = fixture.frame(env)
  local first = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
  local texture = first:getCanvas()[1]
  expect.equal(texture.width, 720, 'the initial target meets the minimum width')
  expect.equal(texture.height, 480, 'the initial target meets the minimum height')
  local textures = #env.recorder.textureAcquisitions
  env.recorder.width, env.recorder.height = 1200, 800
  local sameSize = fixture.preparation(env.renderer.render(env.pass, fixture.frame(env), vector.zero))
  expect.equal(sameSize, first, 'different main dimensions reuse the same pass')
  expect.equal(sameSize:getCanvas()[1], texture, 'different main dimensions reuse the same target')
  expect.equal(#env.recorder.textureAcquisitions, textures, 'same-size reuse allocates nothing')
  env.recorder.width, env.recorder.height = 1920, 1280
  local resized = fixture.preparation(env.renderer.render(env.pass, fixture.frame(env), vector.zero))
  expect.equal(resized:getCanvas()[1].width, 960, 'a larger target has the selected reduced width')
  expect.equal(resized:getCanvas()[1].height, 640, 'a larger target has the selected reduced height')
  expect.truthy(resized:getCanvas()[1] ~= texture, 'the changed target dimensions allocate a new resource')
  expect.equal(texture.released, true, 'successful replacement releases the old texture')
  local count = #env.recorder.textureAcquisitions
  fixture.preparation(env.renderer.render(env.pass, fixture.frame(env), vector.zero))
  expect.equal(#env.recorder.textureAcquisitions, count, 'the resized target is reused')
  fixture.close(env)
end)

test('odd dimensions round up and reuse the same reduced-resolution target', function(): ()
  local env = fixture.boot()
  env.recorder.width, env.recorder.height = 1921, 1281
  local target = fixture.preparation(env.renderer.render(env.pass, fixture.frame(env), vector.zero))
  local texture = target:getCanvas()[1]
  expect.equal(texture.width, 961, 'the final odd column is retained')
  expect.equal(texture.height, 641, 'the final odd row is retained')
  local count = #env.recorder.textureAcquisitions
  env.recorder.width, env.recorder.height = 1922, 1282
  local reused = fixture.preparation(env.renderer.render(env.pass, fixture.frame(env), vector.zero))
  expect.equal(reused, target, 'dimensions with the same rounded reduced size reuse their pass')
  expect.equal(reused:getCanvas()[1], texture, 'dimensions with the same rounded reduced size reuse their texture')
  expect.equal(#env.recorder.textureAcquisitions, count, 'no replacement is allocated')
  fixture.close(env)
end)

test('a previously active renderer records and allocates nothing after context shutdown', function(): ()
  local env = fixture.boot()
  local value = fixture.frame(env)
  local target = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
  fixture.close(env)
  local textures, passes = #env.recorder.textureAcquisitions, #env.recorder.passAcquisitions
  local mainCalls, targetCalls = #env.recorder.calls, #target.recorder.calls
  expect.equal(env.renderer.render(env.pass, value, vector.zero), nil, 'closed scenes return no prerequisite')
  env.renderer.miniature(env.pass, value, 0.5, nil, 1)
  expect.equal(#env.recorder.textureAcquisitions, textures, 'closed renderers acquire no texture')
  expect.equal(#env.recorder.passAcquisitions, passes, 'closed renderers acquire no pass')
  expect.equal(#env.recorder.calls, mainCalls, 'closed renderers record no main commands')
  expect.equal(#target.recorder.calls, targetCalls, 'closed renderers never touch their released pass')
  env.recorder:assertResourcesReleased()
end)

test('scene-first rendering computes in the prerequisite and shares the fields with the miniature', function(): ()
  local env = fixture.boot()
  local value = fixture.frame(env)
  local target = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
  assertComputeBeforeDraw(target.recorder, 2)
  expect.equal(#fixture.calls(env.recorder, 'compute'), 0, 'the main pass depends on prerequisite updates')
  env.renderer.miniature(env.pass, value, 0.5, nil, 0.7)
  expect.equal(
    #fixture.calls(env.recorder, 'compute'),
    0,
    'the miniature reuses updates submitted before the main pass'
  )
  expect.equal(#fixture.calls(env.recorder, 'draw'), 7, 'the miniature still draws its complete direct scene')
  fixture.close(env)
end)

test('miniature-first main-pass computes do not satisfy an earlier submitted prerequisite', function(): ()
  local env = fixture.boot()
  local value = fixture.frame(env)
  env.renderer.miniature(env.pass, value, 0.5, nil, 0.7)
  assertComputeBeforeDraw(env.recorder, 2)
  local target = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
  assertComputeBeforeDraw(target.recorder, 2)
  expect.equal(#fixture.calls(target.recorder, 'draw'), 3, 'the prerequisite consumes its own field updates')
  fixture.close(env)
end)

test('target resets refresh the same Frame and a new Frame at the same clock binds new waves', function(): ()
  local env = fixture.boot()
  local value = fixture.frame(env)
  local target = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
  table.clear(target.recorder.calls)
  local repeated = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
  expect.equal(repeated, target, 'the same target pass is reset and returned')
  expect.equal(#fixture.calls(target.recorder, 'reset'), 1, 'each prerequisite recording starts from reset')
  assertComputeBeforeDraw(target.recorder, 2)
  local nextFrame = fixture.frame(env)
  nextFrame.waves[1].position = 0.23
  table.clear(target.recorder.calls)
  fixture.preparation(env.renderer.render(env.pass, nextFrame, vector.zero))
  assertComputeBeforeDraw(target.recorder, 2)
  local changed = false
  for _, call in fixture.calls(target.recorder, 'send') do
    if call[2] == 'backdropWaves' and call[3][1][3] == 0.23 then
      changed = true
    end
  end
  expect.equal(changed, true, 'a distinct Frame uploads its changed waves even at the same model clock')
  fixture.close(env)
end)

for _, method in { 'compute', 'draw' } do
  test('prerequisite ' .. method .. ' errors restore the main pass and permit a complete retry', function(): ()
    local env = fixture.boot()
    local value = fixture.frame(env)
    local target = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
    local checkpoint = fixture.seedState(env)
    local original = target[method]
    target[method] = function(): ()
      error('injected prerequisite failure', 0)
    end
    expect.raises(function(): { render.Pass }?
      return env.renderer.render(env.pass, fixture.frame(env), vector.zero)
    end, 'injected prerequisite failure')
    target[method] = original
    env.recorder:assertRestored(checkpoint)
    table.clear(target.recorder.calls)
    fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
    assertComputeBeforeDraw(target.recorder, 2)
    expect.equal(#fixture.calls(target.recorder, 'draw'), 3, 'retry records all curtain layers')
    env.recorder:assertRestored(checkpoint)
    fixture.close(env)
  end)
end

test('a main composite error restores the caller state and transform', function(): ()
  local env = fixture.boot()
  local checkpoint = fixture.seedState(env)
  local original = env.pass.mesh
  env.pass.mesh = function(): ()
    error('injected composite failure', 0)
  end
  expect.raises(function(): { render.Pass }?
    return env.renderer.render(env.pass, fixture.frame(env), vector.pack(2, 1, -3))
  end, 'injected composite failure')
  env.pass.mesh = original
  env.recorder:assertRestored(checkpoint)
  fixture.preparation(env.renderer.render(env.pass, fixture.frame(env), vector.zero))
  env.recorder:assertRestored(checkpoint)
  fixture.close(env)
end)

for _, failureAt in { 'newTexture', 'newSampler', 'newShader', 'newPass', 'configure' } do
  test(failureAt .. ' failure releases the partial target in reverse acquisition order', function(): ()
    local env = fixture.boot()
    local value = fixture.frame(env)
    env.recorder.width = 640
    env.renderer.render(env.pass, value, vector.zero)
    env.recorder.width = 960
    env.pass:reset()
    local checkpoint = fixture.seedState(env)
    local originals, acquired, released = {}, {}, {}
    for _, name in { 'newTexture', 'newSampler', 'newShader', 'newPass' } do
      local original = lovr.graphics[name]
      originals[name] = original
      lovr.graphics[name] = function(...: any): any
        if failureAt == name then
          error('injected target acquisition failure', 0)
        end
        local resource = original(...)
        table.insert(acquired, resource)
        local release = resource.release
        resource.release = function(self: any): ()
          table.insert(released, self)
          release(self)
        end
        if name == 'newPass' and failureAt == 'configure' then
          resource.setProjection = function(): ()
            error('injected target acquisition failure', 0)
          end
        end
        return resource
      end
    end
    local ok, failure = pcall(env.renderer.render, env.pass, value, vector.zero)
    for name, original in originals do
      lovr.graphics[name] = original
    end
    expect.equal(ok, false, 'the target acquisition error propagates')
    expect.truthy(tostring(failure):find('injected target acquisition failure', 1, true), 'the error is retained')
    env.recorder:assertRestored(checkpoint)
    expect.equal(#released, #acquired, 'every partial target resource is released')
    for index, resource in acquired do
      expect.equal(resource.released, true, 'no resource escapes partial acquisition')
      expect.equal(released[#released - index + 1], resource, 'cleanup reverses acquisition order')
    end
    expect.equal(#fixture.calls(env.recorder, 'mesh'), 0, 'a failed target is never composited')
    local target = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
    expect.equal(target.released, false, 'a complete target can be acquired on retry')
    fixture.close(env)
  end)
end

for _, failureAt in { 'textureFailure', 'passFailure', 'shaderFailure' } do
  test('failed resize ' .. failureAt .. ' retains the previous usable target', function(): ()
    local env = fixture.boot()
    local value = fixture.frame(env)
    local target = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
    local texture = target:getCanvas()[1]
    env.recorder.width, env.recorder.height = 1920, 1280
    env.recorder[failureAt] = 'injected resize failure'
    local checkpoint = fixture.seedState(env)
    expect.raises(function(): { render.Pass }?
      return env.renderer.render(env.pass, value, vector.zero)
    end, 'injected resize failure')
    env.recorder:assertRestored(checkpoint)
    expect.equal(target.released, false, 'failed replacement does not release the old pass')
    expect.equal(texture.released, false, 'failed replacement does not release the old texture')
    env.recorder.width, env.recorder.height = 960, 640
    local recovered = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
    expect.equal(recovered, target, 'the original dimensions reuse the previous pass')
    expect.equal(recovered:getCanvas()[1], texture, 'the original target remains usable')
    env.recorder.width, env.recorder.height = 1920, 1280
    local replacement = fixture.preparation(env.renderer.render(env.pass, value, vector.zero))
    expect.equal(replacement:getCanvas()[1].width, 960, 'a later reduced-resolution resize retry succeeds')
    expect.equal(
      replacement:getCanvas()[1].height,
      640,
      'a later reduced-resolution resize retry preserves aspect ratio'
    )
    expect.equal(texture.released, true, 'only successful replacement releases the old target')
    fixture.close(env)
  end)
end

return test
