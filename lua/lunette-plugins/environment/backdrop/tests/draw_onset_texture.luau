local testing = require '@testing'
local plugin = require '@lunette-plugin'
local render = require '@testing/render'
local selection = require '../private/selection/selection'
local config = require '../config'
local draw = require '../private/rendering/draw'
local model = require '../private/rendering/model'
local shader = require '../private/rendering/shader'
local waveUniforms = require '../private/rendering/wave-uniforms'
local expect = testing.expect
local test = testing.suite()

type Environment = {
  session: testing.Session,
  recorder: render.Recorder,
  pass: render.Pass,
  renderer: draw.Renderer,
  state: model.State,
  diagnostic: selection.Diagnostic,
}
type Dispatch = { call: render.Call, uniforms: { [string]: render.Argument } }
type Resource = render.Mesh | render.Shader | Texture | render.Sampler

local function boot(): Environment
  local session = testing.boot {}
  local settings = config.schema.parse {}
  local env = {
    session = session,
    recorder = session.native.events.render,
    pass = session.native.events.render.pass,
    state = model.new(settings),
    diagnostic = 'none',
  }
  session:use(plugin.consumer({
    name = 'testing/onset-texture',
    init = function(context: plugin.Context)
      env.renderer = draw.new(context, settings, function(): selection.Diagnostic
        return env.diagnostic
      end)
    end,
  }).definition)
  return env
end

local function frame(env: Environment, count: number, time: number?): model.Frame
  local value = table.clone(env.state:update(0, false))
  value.visibility, value.brightness, value.responseStrength = 1, 0.8, 0.6
  value.time = time or 23
  value.waves = {}
  local bands = { 'treble', 'bass', 'mid', 'bass', 'mid' }
  for index = 1, count do
    local band = bands[(index - 1) % #bands + 1]
    value.waves[index] = {
      age = 0.08 + index * 0.001,
      strength = 0.7,
      position = index / (model.MAX_WAVES + 4),
      frequency = index / (model.MAX_WAVES + 4),
      band = band,
      lifetime = model.waveLifetimes[band],
    }
  end
  return value
end

local function dispatches(env: Environment): { Dispatch }
  local current, uniforms, found = nil, {}, {}
  for _, call in env.recorder.calls do
    if call[1] == 'setShader' then
      current, uniforms = call[2], {}
    elseif call[1] == 'send' then
      uniforms[call[2]] = call[3]
    elseif call[1] == 'compute' and current.compute == shader.curtainCompute then
      table.insert(found, { call = call, uniforms = table.clone(uniforms) })
    end
  end
  return found
end

local function assertBindings(env: Environment, expectedCount: number): ()
  local current, uniforms, draws = nil, {}, 0
  for _, call in env.recorder.calls do
    if call[1] == 'setShader' then
      current, uniforms = call[2], {}
    elseif call[1] == 'send' then
      uniforms[call[2]] = call[3]
    elseif call[1] == 'draw' and current.fragment == shader.curtainCachedFragment then
      draws += 1
      expect.equal(uniforms.onsetPulses, env.recorder.textureAcquisitions[2], 'every curtain binds the pulse texture')
      expect.equal(uniforms.onsetZones, env.recorder.textureAcquisitions[3], 'every curtain binds the altitude texture')
      expect.equal(uniforms.onsetSampler, env.recorder.samplerAcquisitions[2], 'every curtain binds its sampler')
      expect.equal(uniforms.backdropWaveCount, expectedCount, 'the branch receives the current live count')
    end
  end
  expect.truthy(draws > 0, 'the normal view draws the cached curtain shader')
end

local function close(env: Environment): ()
  env.session:close()
  env.recorder:assertResourcesReleased()
end

for _, miniatureFirst in { false, true } do
  test(
    (if miniatureFirst then 'miniature then scene' else 'scene then miniature') .. ' shares one dense onset field',
    function()
      local env = boot()
      local value = frame(env, model.MAX_WAVES)
      env.pass:setShader 'unlit'
      env.pass:translate(2, 3, 4)
      local checkpoint = env.recorder:checkpoint()
      if miniatureFirst then
        env.renderer.miniature(env.pass, value, 0.5, nil, 0.7)
        env.renderer.render(env.pass, value, vector.zero)
      else
        env.renderer.render(env.pass, value, vector.zero)
        env.renderer.miniature(env.pass, value, 0.5, nil, 0.7)
      end
      env.renderer.render(env.pass, value, vector.zero)
      env.recorder:assertRestored(checkpoint)
      local found = dispatches(env)
      expect.equal(#found, 1, 'the scene, miniature, and repeated eye draw share one onset dispatch')
      expect.equal(found[1].call[2], 64, 'the field uses 8-wide workgroups')
      expect.equal(found[1].call[3], 8, 'the field uses 8-high workgroups')
      expect.equal(found[1].call[4], 1, 'the field has one layer')
      expect.equal(found[1].uniforms.onsetPulsesImage, env.recorder.textureAcquisitions[2], 'compute writes raw pulses')
      expect.equal(
        found[1].uniforms.onsetZonesImage,
        env.recorder.textureAcquisitions[3],
        'compute writes altitude weights'
      )
      for _, name in { 'backdropScene', 'backdropSky', 'backdropFocus', 'backdropResponse' } do
        expect.equal(found[1].uniforms[name], nil, 'the onset field has no focus, opacity, brightness, or clock input')
      end
      local waves, details, ends, live = waveUniforms.prepare(value.waves, value.responseStrength)
      expect.equal(found[1].uniforms.backdropWaveCount, live, 'compute receives the clamped live count')
      for index = 1, live do
        for lane = 1, 4 do
          expect.equal(
            found[1].uniforms.backdropWaves[index][lane],
            waves[index][lane],
            'compute receives stable grouped waves'
          )
          expect.equal(
            found[1].uniforms.backdropWaveDetail[index][lane],
            details[index][lane],
            'compute receives prepared detail'
          )
        end
      end
      for lane = 1, 4 do
        expect.equal(found[1].uniforms.backdropWaveEnds[lane], ends[lane], 'compute receives cumulative band ends')
      end
      local draws, computes = 0, 0
      for _, call in env.recorder.calls do
        if call[1] == 'compute' then
          computes += 1
          expect.equal(draws, 0, 'both dispatches precede the first draw')
        elseif call[1] == 'draw' then
          draws += 1
          expect.equal(computes, 2, 'drawing follows the sky and onset dispatches')
        end
      end
      expect.equal(draws, 15, 'sharing does not add draw calls')
      assertBindings(env, live)
      expect.equal(#env.recorder.meshAcquisitions, 3, 'the geometry resources are unchanged')
      expect.equal(#env.recorder.shaderAcquisitions, 5, 'one onset compute shader joins the existing shaders')
      expect.equal(#env.recorder.textureAcquisitions, 3, 'two onset textures join the sky texture')
      expect.equal(#env.recorder.samplerAcquisitions, 2, 'one onset sampler joins the sky sampler')
      for index, height in { [2] = 1, [3] = 64 } do
        local texture = env.recorder.textureAcquisitions[index]
        expect.equal(texture.width, 512, 'both onset textures share the longitude resolution')
        expect.equal(texture.height, height, 'raw pulses and altitude weights have separate heights')
        expect.equal(texture.options.type, '2d', 'the fields are two-dimensional')
        expect.equal(texture.options.format, 'rgba16f', 'the fields store half-float band sums')
        expect.equal(texture.options.linear, true, 'the fields store linear values')
        expect.equal(texture.options.samples, 1, 'the fields are not multisampled')
        expect.equal(texture.options.mipmaps, false, 'the fields have no mipmaps')
        expect.equal(texture.options.usage[1], 'sample', 'the fields support sampling')
        expect.equal(texture.options.usage[2], 'storage', 'the fields support compute writes')
      end
      local sampler = env.recorder.samplerAcquisitions[2]
      expect.equal(sampler.options.filter, 'linear', 'the onset lookup uses bilinear filtering')
      expect.equal(
        table.concat(sampler.options.wrap, ','),
        'repeat,clamp,clamp',
        'longitude repeats and altitude clamps'
      )
      expect.equal(sampler.options.mipmaprange[1], 0, 'sampling starts at the base level')
      expect.equal(sampler.options.mipmaprange[2], 0, 'sampling ends at the base level')
      close(env)
    end
  )
end

test('sparse, dense, and silent Frames select the current path without clearing unused textures', function()
  local env = boot()
  for _, count in { 0, 1, 8, 9, model.MAX_WAVES + 3, 0, 8, 9, 0 } do
    local value = frame(env, count)
    table.clear(env.recorder.calls)
    local checkpoint = env.recorder:checkpoint()
    env.renderer.render(env.pass, value, vector.zero)
    env.renderer.miniature(env.pass, value, 0.5, nil, 1)
    env.recorder:assertRestored(checkpoint)
    expect.equal(#dispatches(env), if count > 8 then 1 else 0, 'only dense Frames need a field update')
    assertBindings(env, math.min(count, model.MAX_WAVES))
  end
  expect.equal(#env.recorder.textureAcquisitions, 3, 'transitions reuse the owned textures')
  close(env)
end)

test('distinct dense Frames refresh at the same clock value and across the wrap', function()
  local env = boot()
  for _, time in { 23, 23, 4095.99, 0 } do
    local value = frame(env, 9, time)
    table.clear(env.recorder.calls)
    env.renderer.render(env.pass, value, vector.zero)
    env.renderer.miniature(env.pass, value, 0.5, nil, 1)
    expect.equal(#dispatches(env), 1, 'the Frame identity rather than model time controls the update')
  end
  expect.equal(#env.recorder.shaderAcquisitions, 5, 'new Frames reuse their compute shader')
  close(env)
end)

test('a diagnostic leaves the onset update available to a miniature of the same Frame', function()
  local env = boot()
  local value = frame(env, 9)
  env.diagnostic = 'field'
  env.renderer.render(env.pass, value, vector.zero)
  expect.equal(#dispatches(env), 0, 'diagnostics do not update the curtain field')
  env.renderer.miniature(env.pass, value, 0.5, nil, 0.5)
  expect.equal(#dispatches(env), 1, 'the miniature computes the same Frame on demand')
  env.diagnostic = 'none'
  env.renderer.render(env.pass, value, vector.zero)
  expect.equal(#dispatches(env), 1, 'the normal scene reuses the miniature update')
  close(env)
end)

test('invisible and dark dense draws do not consume the onset Frame marker', function()
  local env = boot()
  local value = frame(env, 9)
  value.visibility = 0
  env.renderer.render(env.pass, value, vector.zero)
  env.renderer.miniature(env.pass, value, 0.5, nil, 0)
  expect.equal(#env.recorder.textureAcquisitions, 0, 'skipped draws do not acquire resources')
  value.brightness = 0
  env.renderer.miniature(env.pass, value, 0.5, nil, 1)
  expect.equal(#dispatches(env), 0, 'a dark curtain does not update the onset field')
  assertBindings(env, 9)
  value.brightness = 0.8
  env.renderer.miniature(env.pass, value, 0.5, nil, 1)
  expect.equal(#dispatches(env), 1, 'positive brightness can update the same Frame')
  close(env)
end)

for _, failAt in { 'send', 'compute' } do
  test('onset ' .. failAt .. ' failure restores state and retries independently of the sky', function()
    local env = boot()
    local value = frame(env, 9)
    local original = env.pass[failAt]
    local failed = false
    env.pass[failAt] = function(self: render.Pass, ...: render.Argument): ()
      local args = { ... }
      local isOnset = if failAt == 'send' then args[1] == 'onsetZonesImage' else args[1] == 64
      if isOnset and not failed then
        failed = true
        error('injected onset recording failure', 0)
      end
      original(self, ...)
    end
    env.pass:setShader 'unlit'
    env.pass:translate(2, 3, 4)
    local checkpoint = env.recorder:checkpoint()
    local ok, failure = pcall(env.renderer.render, env.pass, value, vector.zero)
    env.pass[failAt] = original
    expect.equal(ok, false, 'the onset recording failure propagates')
    expect.truthy(string.find(tostring(failure), 'injected onset recording failure', 1, true), 'the error is retained')
    env.recorder:assertRestored(checkpoint)
    expect.equal(#dispatches(env), 0, 'a failed onset update is not recorded')
    for _, call in env.recorder.calls do
      expect.truthy(call[1] ~= 'draw', 'no draw consumes an unrecorded field')
    end
    table.clear(env.recorder.calls)
    env.renderer.miniature(env.pass, value, 0.5, nil, 1)
    local computes = 0
    for _, call in env.recorder.calls do
      if call[1] == 'compute' then
        computes += 1
      end
    end
    expect.equal(computes, 1, 'the successful sky update is not repeated')
    expect.equal(#dispatches(env), 1, 'the onset update retries for the same Frame')
    env.recorder:assertRestored(checkpoint)
    env.renderer.render(env.pass, value, vector.zero)
    expect.equal(#dispatches(env), 1, 'a successful onset update is not repeated')
    close(env)
  end)
end

test('a draw failure after dense compute retains both successful Frame markers', function()
  local env = boot()
  local value = frame(env, 9)
  local original = env.pass.draw
  env.pass.draw = function()
    error('injected draw failure', 0)
  end
  local checkpoint = env.recorder:checkpoint()
  local ok = pcall(env.renderer.render, env.pass, value, vector.zero)
  env.pass.draw = original
  expect.equal(ok, false, 'the draw failure propagates')
  env.recorder:assertRestored(checkpoint)
  expect.equal(#dispatches(env), 1, 'compute completes before the failing draw')
  table.clear(env.recorder.calls)
  env.renderer.miniature(env.pass, value, 0.5, nil, 1)
  for _, call in env.recorder.calls do
    expect.truthy(call[1] ~= 'compute', 'a later draw reuses both recorded fields')
  end
  close(env)
end)

for _, failureAt in { 'shader5', 'texture2', 'texture3', 'sampler2' } do
  test(failureAt .. ' failure releases partial onset resources in reverse order and retries', function()
    local env = boot()
    local originals, counts, acquired, released = {}, {}, {}, {}
    for name, kind in { newMesh = 'mesh', newShader = 'shader', newTexture = 'texture', newSampler = 'sampler' } do
      local original = lovr.graphics[name]
      originals[name] = original
      counts[kind] = 0
      lovr.graphics[name] = function(...: render.Argument): Resource
        counts[kind] += 1
        local label = kind .. tostring(counts[kind])
        if label == failureAt then
          error('injected ' .. label .. ' acquisition failure', 0)
        end
        local resource = original(...)
        table.insert(acquired, label)
        local release = resource.release
        resource.release = function(self: Resource): ()
          table.insert(released, label)
          release(self)
        end
        return resource
      end
    end
    local checkpoint = env.recorder:checkpoint()
    local value = frame(env, 9)
    local ok, failure = pcall(env.renderer.render, env.pass, value, vector.zero)
    for name, original in originals do
      lovr.graphics[name] = original
    end
    expect.equal(ok, false, 'the acquisition failure propagates')
    expect.truthy(string.find(tostring(failure), 'injected ' .. failureAt, 1, true), 'the resource error is retained')
    env.recorder:assertRestored(checkpoint)
    env.recorder:assertResourcesReleased()
    for _, call in env.recorder.calls do
      expect.truthy(call[1] ~= 'compute' and call[1] ~= 'draw', 'failed acquisition records no compute or draws')
    end
    expect.equal(#released, #acquired, 'every partial resource is released')
    for index, label in acquired do
      expect.equal(released[#released - index + 1], label, 'partial cleanup reverses acquisition order')
    end
    env.renderer.render(env.pass, value, vector.zero)
    expect.equal(#dispatches(env), 1, 'retry acquires a complete onset resource set')
    close(env)
  end)
end

return test
