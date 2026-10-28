local testing = require '@testing'
local plugin = require '@lunette-plugin'
local render = require '@testing/render'
local config = require '../config'
local draw = require '../private/rendering/draw'
local model = require '../private/rendering/model'
local selection = require '../private/selection/selection'
local shader = require '../private/rendering/shader'
local expect = testing.expect
local test = testing.suite()

type Environment = {
  session: testing.Session,
  recorder: render.Recorder,
  pass: render.Pass,
  renderer: draw.Renderer,
  settings: config.Settings,
  state: model.State,
  diagnostic: selection.Diagnostic,
}

local function boot(): Environment
  local session = testing.boot {}
  local settings = config.schema.parse {}
  local env = {
    session = session,
    recorder = session.native.events.render,
    pass = session.native.events.render.pass,
    settings = settings,
    state = model.new(settings),
    diagnostic = 'none',
  }
  env.instance = session:use(plugin.consumer({
    name = 'testing/sky-texture',
    init = function(context: plugin.Context): ()
      env.renderer = draw.new(context, settings, function(): selection.Diagnostic
        return env.diagnostic
      end)
    end,
  }).definition)
  return env
end

local function frame(env: Environment, time: number?): model.Frame
  local value = table.clone(env.state:update(0, false))
  value.visibility = 1
  value.brightness = 0.8
  value.time = time or 23
  value.bass, value.mid, value.treble = 0.2, 0.4, 0.6
  return value
end

local function calls(env: Environment, method: string): { render.Call }
  local found = {}
  for _, call in env.recorder.calls do
    if call[1] == method then
      found[#found + 1] = call
    end
  end
  return found
end

local function close(env: Environment): ()
  env.session:close()
  env.recorder:assertResourcesReleased()
end

for _, miniatureFirst in { false, true } do
  test(
    (if miniatureFirst then 'miniature then scene' else 'scene then miniature') .. ' records one field',
    function(): ()
      local env = boot()
      local value = frame(env)
      local checkpoint = env.recorder:checkpoint()
      if miniatureFirst then
        env.renderer.miniature(env.pass, value, 0.5, nil, 0.7)
        env.renderer.render(env.pass, value, vector.zero)
      else
        env.renderer.render(env.pass, value, vector.zero)
        env.renderer.miniature(env.pass, value, 0.5, nil, 0.7)
      end
      env.recorder:assertRestored(checkpoint)
      expect.equal(#calls(env, 'compute'), 1, 'the shared Frame dispatches once')
      expect.equal(#calls(env, 'draw'), 10, 'both methods retain their five draws')
      local current, uniforms, draws, dispatches = nil, {}, 0, 0
      for _, call in env.recorder.calls do
        if call[1] == 'setShader' then
          current = call[2]
        elseif call[1] == 'send' then
          uniforms[call[2]] = call[3]
        elseif call[1] == 'compute' then
          dispatches += 1
          expect.equal(draws, 0, 'the field is recorded before either scene draws')
          expect.equal(current.compute, shader.skyCompute, 'the production compute shader records the field')
          expect.equal(call[2], 48, 'the width uses 8-wide workgroups')
          expect.equal(call[3], 48, 'the height uses 8-high workgroups')
          expect.equal(call[4], 1, 'the field has one layer')
          expect.equal(call.draw, nil, 'compute is not a drawing call')
          expect.equal(uniforms.overheadImage, env.recorder.textureAcquisitions[1], 'compute writes the owned texture')
          expect.equal(uniforms.backdropSky[1], 0, 'visibility is absent from the field inputs')
          expect.equal(uniforms.backdropSky[2], value.time, 'the model time reaches compute')
          expect.equal(uniforms.backdropSky[3], 0, 'brightness is absent from the field inputs')
          expect.equal(uniforms.backdropResponse[1], value.bass, 'the bass energy reaches compute')
          expect.equal(uniforms.backdropResponse[2], value.mid, 'the mid energy reaches compute')
          expect.equal(uniforms.backdropResponse[3], value.treble, 'the treble energy reaches compute')
          expect.equal(uniforms.backdropMid[1], env.settings.palette.mid[1], 'the mid palette reaches compute')
          expect.equal(uniforms.backdropTreble[3], env.settings.palette.treble[3], 'the treble palette reaches compute')
        elseif call[1] == 'draw' then
          draws += 1
          expect.equal(dispatches, 1, 'every normal draw follows the sole dispatch')
          if current.fragment == shader.skyCachedFragment then
            expect.equal(
              uniforms.overheadTexture,
              env.recorder.textureAcquisitions[1],
              'the sky samples the written field'
            )
            expect.equal(
              uniforms.overheadSampler,
              env.recorder.samplerAcquisitions[1],
              'the sky uses the owned sampler'
            )
          end
        end
      end
      expect.equal(#env.recorder.meshAcquisitions, 3, 'the geometry count is unchanged')
      expect.equal(
        #env.recorder.shaderAcquisitions,
        4,
        'the renderer owns three graphics shaders and one compute shader'
      )
      expect.equal(
        env.recorder.shaderAcquisitions[1].fragment,
        shader.skyCachedFragment,
        'normal rendering uses the cached variant'
      )
      expect.equal(#env.recorder.textureAcquisitions, 1, 'the methods share one texture')
      expect.equal(#env.recorder.samplerAcquisitions, 1, 'the methods share one sampler')
      local texture = env.recorder.textureAcquisitions[1]
      expect.equal(texture.width, 384, 'the field width is fixed')
      expect.equal(texture.height, 384, 'the field height is fixed')
      expect.equal(texture.options.type, '2d', 'the field is two-dimensional')
      expect.equal(texture.options.format, 'rgba16f', 'the field uses half-float RGB with an unused alpha')
      expect.equal(texture.options.linear, true, 'the field stores linear light')
      expect.equal(texture.options.samples, 1, 'the field is not multisampled')
      expect.equal(texture.options.mipmaps, false, 'the field has no mipmaps')
      expect.equal(texture.options.usage[1], 'sample', 'the field can be sampled')
      expect.equal(texture.options.usage[2], 'storage', 'the field can be written by compute')
      local sampler = env.recorder.samplerAcquisitions[1]
      expect.equal(sampler.options.filter, 'linear', 'the field has bilinear filtering')
      expect.equal(sampler.options.wrap, 'clamp', 'the square margin clamps at its edges')
      expect.equal(sampler.options.mipmaprange[1], 0, 'only the base level can be sampled')
      expect.equal(sampler.options.mipmaprange[2], 0, 'only the base level can be sampled')
      close(env)
    end
  )
end

test('new Frame identities refresh at the same model time and across the clock wrap', function(): ()
  local env = boot()
  for _, time in { 23, 23, 4095.99, 0 } do
    local value = frame(env, time)
    table.clear(env.recorder.calls)
    env.renderer.render(env.pass, value, vector.zero)
    env.renderer.miniature(env.pass, value, 0.5, nil, 1)
    expect.equal(#calls(env, 'compute'), 1, 'each new Frame records one field even when the clock does not change')
  end
  expect.equal(#env.recorder.textureAcquisitions, 1, 'new Frames reuse the same texture')
  expect.equal(#env.recorder.samplerAcquisitions, 1, 'new Frames reuse the same sampler')
  close(env)
end)

test('diagnostics bind valid resources without dispatch and a normal draw of the same Frame refreshes', function(): ()
  local env = boot()
  local value = frame(env)
  for _, diagnostic in { 'direction', 'coordinates', 'cells', 'density', 'field' } do
    env.diagnostic = diagnostic
    table.clear(env.recorder.calls)
    env.renderer.render(env.pass, value, vector.zero)
    expect.equal(#calls(env, 'compute'), 0, 'analytic diagnostics do not generate the field texture')
    expect.equal(#calls(env, 'draw'), 1, 'a diagnostic replaces the curtains and fragments')
    local texture, sampler = nil, nil
    for _, call in calls(env, 'send') do
      if call[2] == 'overheadTexture' then
        texture = call[3]
      elseif call[2] == 'overheadSampler' then
        sampler = call[3]
      end
    end
    expect.equal(texture, env.recorder.textureAcquisitions[1], 'diagnostics bind a valid texture descriptor')
    expect.equal(sampler, env.recorder.samplerAcquisitions[1], 'diagnostics bind a valid sampler descriptor')
  end
  table.clear(env.recorder.calls)
  env.renderer.miniature(env.pass, value, 0.5, nil, 1)
  expect.equal(#calls(env, 'compute'), 1, 'the miniature requests a field despite the main diagnostic')
  env.diagnostic = 'none'
  env.renderer.render(env.pass, value, vector.zero)
  expect.equal(#calls(env, 'compute'), 1, 'the normal main draw reuses the miniature field')
  close(env)
end)

test('a main diagnostic-to-normal transition computes the same Frame on demand', function(): ()
  local env = boot()
  local value = frame(env)
  env.diagnostic = 'field'
  env.renderer.render(env.pass, value, vector.zero)
  expect.equal(#calls(env, 'compute'), 0, 'the diagnostic leaves the field uncomputed')
  env.diagnostic = 'none'
  env.renderer.render(env.pass, value, vector.zero)
  expect.equal(#calls(env, 'compute'), 1, 'the normal view generates the field for the same Frame')
  close(env)
end)

test('a first zero-brightness draw binds valid resources without computing an unread field', function(): ()
  local env = boot()
  local value = frame(env)
  value.brightness = 0
  env.renderer.render(env.pass, value, vector.zero)
  expect.equal(#calls(env, 'compute'), 0, 'the first dark draw does not dispatch')
  expect.equal(#calls(env, 'draw'), 5, 'the normal draws remain present')
  local texture, sampler = nil, nil
  for _, call in calls(env, 'send') do
    if call[2] == 'overheadTexture' then
      texture = call[3]
    elseif call[2] == 'overheadSampler' then
      sampler = call[3]
    end
  end
  expect.equal(texture, env.recorder.textureAcquisitions[1], 'the dark draw has a valid texture descriptor')
  expect.equal(sampler, env.recorder.samplerAcquisitions[1], 'the dark draw has a valid sampler descriptor')
  value.brightness = 1
  env.renderer.miniature(env.pass, value, 0.5, nil, 1)
  expect.equal(#calls(env, 'compute'), 1, 'the first visible contribution generates the same Frame')
  close(env)
end)

test('skipped and zero-brightness draws do not mark a Frame as computed', function(): ()
  local env = boot()
  local value = frame(env)
  value.visibility = 0
  env.renderer.render(env.pass, value, vector.zero)
  env.renderer.miniature(env.pass, value, 0.5, nil, 0)
  expect.equal(#env.recorder.meshAcquisitions, 0, 'invisible draws acquire nothing')
  expect.equal(#calls(env, 'compute'), 0, 'invisible draws dispatch nothing')
  env.renderer.miniature(env.pass, value, 0.5, nil, 0.8)
  expect.equal(#calls(env, 'compute'), 1, 'the miniature generates a field while the main scene is invisible')
  local dark = frame(env)
  dark.brightness = 0
  table.clear(env.recorder.calls)
  env.renderer.render(env.pass, dark, vector.zero)
  expect.equal(#calls(env, 'compute'), 0, 'zero brightness skips the field')
  expect.equal(#calls(env, 'draw'), 5, 'zero brightness retains normal draw behavior')
  dark.brightness = 0.8
  env.renderer.render(env.pass, dark, vector.zero)
  expect.equal(#calls(env, 'compute'), 1, 'a positive brightness can still generate the same Frame')
  local skipped = frame(env, 123)
  skipped.visibility = 0
  env.renderer.render(env.pass, skipped, vector.zero)
  local nextFrame = frame(env, 123)
  table.clear(env.recorder.calls)
  env.renderer.render(env.pass, nextFrame, vector.zero)
  expect.equal(#calls(env, 'compute'), 1, 'a dropped update does not prevent the next visible Frame')
  close(env)
end)

test('compute recording errors restore state and permit a retry of the same Frame', function(): ()
  local env = boot()
  local value = frame(env)
  env.pass:setShader 'unlit'
  env.pass:translate(2, 3, 4)
  local checkpoint = env.recorder:checkpoint()
  local original = env.pass.compute
  env.pass.compute = function(): ()
    error('injected compute recording failure', 0)
  end
  local ok, failure = pcall(env.renderer.render, env.pass, value, vector.zero)
  expect.equal(ok, false, 'the recording failure propagates')
  expect.truthy(string.find(tostring(failure), 'injected compute recording failure', 1, true), 'the error is retained')
  env.recorder:assertRestored(checkpoint)
  expect.equal(#calls(env, 'draw'), 0, 'an unrecorded field is never drawn')
  env.pass.compute = original
  table.clear(env.recorder.calls)
  env.renderer.render(env.pass, value, vector.zero)
  expect.equal(#calls(env, 'compute'), 1, 'only a successful recording marks the Frame')
  env.recorder:assertRestored(checkpoint)
  close(env)
end)

for _, failureAt in { 'shader1', 'shader2', 'shader3', 'shader4', 'texture', 'sampler' } do
  test(failureAt .. ' acquisition failure releases every partial resource and retries', function(): ()
    local env = boot()
    local value = frame(env)
    local original = lovr.graphics.newShader
    local count = 0
    lovr.graphics.newShader = function(...: any): any
      count += 1
      if failureAt == 'shader' .. tostring(count) then
        error('injected ' .. failureAt .. ' failure', 0)
      end
      return original(...)
    end
    if failureAt == 'texture' then
      env.recorder.textureFailure = 'injected texture failure'
    elseif failureAt == 'sampler' then
      env.recorder.samplerFailure = 'injected sampler failure'
    end
    local checkpoint = env.recorder:checkpoint()
    local ok, failure = pcall(env.renderer.render, env.pass, value, vector.zero)
    expect.equal(ok, false, 'the acquisition failure propagates')
    expect.truthy(
      string.find(tostring(failure), 'injected ' .. failureAt .. ' failure', 1, true),
      'the error is retained'
    )
    env.recorder:assertRestored(checkpoint)
    env.recorder:assertResourcesReleased()
    expect.equal(#calls(env, 'compute'), 0, 'failed acquisition records no compute')
    expect.equal(#calls(env, 'draw'), 0, 'failed acquisition records no draw')
    lovr.graphics.newShader = original
    env.renderer.render(env.pass, value, vector.zero)
    expect.equal(#calls(env, 'compute'), 1, 'retry acquires a complete resource set')
    close(env)
  end)
end

test('draw failure after compute restores state without recording the same field twice', function(): ()
  local env = boot()
  local value = frame(env)
  local checkpoint = env.recorder:checkpoint()
  local original = env.pass.draw
  env.pass.draw = function(): ()
    error('injected sky draw failure', 0)
  end
  local ok, failure = pcall(env.renderer.render, env.pass, value, vector.zero)
  expect.equal(ok, false, 'the sky draw failure propagates')
  expect.truthy(string.find(tostring(failure), 'injected sky draw failure', 1, true), 'the error is retained')
  env.recorder:assertRestored(checkpoint)
  expect.equal(#calls(env, 'compute'), 1, 'the successful compute remains recorded')
  env.pass.draw = original
  env.renderer.miniature(env.pass, value, 0.5, nil, 1)
  expect.equal(#calls(env, 'compute'), 1, 'the miniature reuses the successfully recorded field')
  env.recorder:assertRestored(checkpoint)
  close(env)
end)

test('cancelled effect registration releases the complete acquisition before returning', function(): ()
  local env = boot()
  local value = frame(env)
  local original = lovr.graphics.newSampler
  lovr.graphics.newSampler = function(...: any): any
    local sampler = original(...)
    env.instance:disable()
    return sampler
  end
  local checkpoint = env.recorder:checkpoint()
  local ok, failure = pcall(env.renderer.render, env.pass, value, vector.zero)
  lovr.graphics.newSampler = original
  expect.equal(ok, false, 'a cancelled acquisition cannot escape the effect registration')
  expect.truthy(string.find(tostring(failure), 'cancel', 1, true), 'the registration reports cancellation')
  expect.equal(#env.recorder.shaderAcquisitions, 4, 'cancellation follows the complete shader acquisition')
  expect.equal(#env.recorder.textureAcquisitions, 1, 'cancellation includes the field texture')
  expect.equal(#env.recorder.samplerAcquisitions, 1, 'cancellation includes the sampler')
  env.recorder:assertResourcesReleased()
  env.recorder:assertRestored(checkpoint)
  expect.equal(#calls(env, 'compute'), 0, 'cancelled registration records no compute')
  expect.equal(#calls(env, 'draw'), 0, 'cancelled registration records no draw')
  close(env)
end)

for _, partial in { false, true } do
  test(
    (if partial then 'partial acquisition' else 'registered resource')
      .. ' cleanup releases in reverse order despite errors',
    function(): ()
      local env = boot()
      local releases = {}
      local originals = {}
      local function wrap(name: string): ()
        local original = lovr.graphics[name]
        originals[name] = original
        lovr.graphics[name] = function(...: any): any
          local resource = original(...)
          local release = resource.release
          local label = if name == 'newMesh'
            then 'mesh' .. tostring(#env.recorder.meshAcquisitions)
            elseif name == 'newShader' then 'shader' .. tostring(#env.recorder.shaderAcquisitions)
            elseif name == 'newTexture' then 'texture'
            else 'sampler'
          resource.release = function(self: any): ()
            table.insert(releases, label)
            release(self)
            if label == 'texture' or label == 'shader4' then
              error('injected release ' .. label .. ' failure', 0)
            end
          end
          return resource
        end
      end
      for _, name in { 'newMesh', 'newShader', 'newTexture', 'newSampler' } do
        wrap(name)
      end
      if partial then
        env.recorder.samplerFailure = 'injected sampler acquisition failure'
      end
      local ok, failure = pcall(env.renderer.render, env.pass, frame(env), vector.zero)
      for name, original in originals do
        lovr.graphics[name] = original
      end
      if not partial then
        expect.equal(ok, true, 'the initial acquisition succeeds')
        local released = env.recorder.samplerAcquisitions[1]
        expect.equal(released.released, false, 'the registered sampler remains live until owner shutdown')
        env.instance:disable()
        env.session.runtime:drain()
        local reports = testing.takeReports()
        expect.equal(#reports, 1, 'the owner reports aggregated cleanup errors')
        failure = testing.diagnostic(env.session.runtime, env.instance)
      else
        expect.equal(ok, false, 'the final acquisition failure propagates')
        expect.truthy(
          string.find(tostring(failure), 'injected sampler acquisition failure', 1, true),
          'the acquisition error survives cleanup'
        )
      end
      expect.truthy(
        string.find(tostring(failure), 'injected release texture failure', 1, true),
        'the texture cleanup error is retained'
      )
      expect.truthy(
        string.find(tostring(failure), 'injected release shader4 failure', 1, true),
        'the compute cleanup error is retained'
      )
      expect.equal(
        table.concat(releases, ','),
        (if partial then '' else 'sampler,') .. 'texture,shader4,shader3,shader2,shader1,mesh3,mesh2,mesh1',
        'every resource releases in reverse acquisition order'
      )
      env.recorder:assertResourcesReleased()
      env.recorder:assertRestored()
      close(env)
    end
  )
end

test('retained renderer callbacks do not use resources after context shutdown', function(): ()
  local env = boot()
  local value = frame(env)
  env.renderer.render(env.pass, value, vector.zero)
  close(env)
  table.clear(env.recorder.calls)
  env.renderer.render(env.pass, frame(env), vector.zero)
  env.renderer.miniature(env.pass, value, 0.5, nil, 1)
  expect.equal(#env.recorder.calls, 0, 'inactive context gating prevents every resource use')
end)

return test
