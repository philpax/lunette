-- Lazily owns the backdrop's GPU resources and restores every touched pass state on errors.
local plugin = require '@lunette-plugin'
local passState = require '@lunette-plugins/graphics/pass-state'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local config = require '../../config'
local geometry = require './geometry'
local model = require './model'
local selection = require '../selection/selection'
local shader = require './shader'
local waveUniforms = require './wave-uniforms'

local draw = {}
export type Renderer = {
  read render: (Pass, model.Frame, vector, number?) -> (),
  -- Draws the backdrop as a model about the pass's origin, scaled from its distance to `radius` metres and seen from
  -- outside: the far half of the sky's shell, with the curtains and fragments inside it, at an opacity. The model
  -- shows whether or not the backdrop itself is visible, and always draws normally rather than in a diagnostic view.
  read miniature: (Pass, model.Frame, number, number?, number) -> (),
}
type Resources = {
  sky: Mesh,
  curtain: Mesh,
  wisps: Mesh,
  skyShader: Shader,
  curtainShader: Shader,
  wispShader: Shader,
  skyCompute: Shader,
  overheadTexture: Texture,
  overheadSampler: Sampler,
  lastFrame: model.Frame?,
}
local acquireResources: (plugin.Context, config.Settings) -> Resources
local drawScene: (Pass, Resources, config.Settings, model.Frame, number, number?, number, ('front' | 'back')?) -> ()
-- The sky shader's diagnostic views, by index; zero draws the backdrop normally.
local DIAGNOSTIC = table.freeze {
  none = 0,
  direction = 1,
  coordinates = 2,
  cells = 3,
  density = 4,
  field = 5,
} :: { read [selection.Diagnostic]: number }
-- Each layer leans toward one band, inner to outer: bass, mid, then treble.
local LAYER_FOCUS = table.freeze {
  table.freeze { 1.6, 0.6, 0.6, 0 },
  table.freeze { 0.6, 1.6, 0.6, 0 },
  table.freeze { 0.6, 0.6, 1.6, 0 },
}

-- The diagnostic view is read every frame, so the controls panel can switch it live.
function draw.new(context: plugin.Context, settings: config.Settings, diagnostic: () -> selection.Diagnostic): Renderer
  local resources: Resources? = nil
  return table.freeze {
    render = function(pass: Pass, frame: model.Frame, headPosition: vector, facing: number?): ()
      if frame.visibility <= 0 or not context:active() then
        return
      end
      passState.withRestore(pass, function(): ()
        local held: Resources = resources or acquireResources(context, settings)
        resources = held
        pass:origin()
        pass:translate(headPosition)
        pass:setDepthTest()
        pass:setDepthWrite(false)
        pass:setCullMode(nil)
        pass:setMaterial(nil)
        pass:setBlendMode('alpha', 'premultiplied')
        pass:setColor(1, 1, 1, 1)
        drawScene(pass, held, settings, frame, frame.visibility, facing, DIAGNOSTIC[diagnostic()], nil)
      end)
    end,
    miniature = function(pass: Pass, frame: model.Frame, radius: number, facing: number?, opacity: number): ()
      if opacity <= 0 or not context:active() then
        return
      end
      passState.withRestore(pass, function(): ()
        local held: Resources = resources or acquireResources(context, settings)
        resources = held
        pass:scale(radius / settings.distance)
        pass:setDepthWrite(false)
        pass:setMaterial(nil)
        pass:setBlendMode('alpha', 'premultiplied')
        pass:setColor(1, 1, 1, 1)
        -- The sky is a sphere drawn from inside, so from outside its near half shows its back faces. Culling them
        -- leaves the far half as the model's backdrop.
        drawScene(pass, held, settings, frame, opacity, facing, 0, 'back')
      end)
    end,
  }
end

-- Draws the sky, then the curtain layers and fragments unless a diagnostic view replaces them. `skyCull` culls the
-- sky's faces for a model seen from outside.
drawScene = function(
  pass: Pass,
  held: Resources,
  settings: config.Settings,
  frame: model.Frame,
  visibility: number,
  facing: number?,
  view: number,
  skyCull: ('front' | 'back')?
): ()
  local response = { frame.bass, frame.mid, frame.treble, frame.brightness }
  if view == 0 and frame.brightness > 0 and held.lastFrame ~= frame then
    -- Scene and miniature share one Frame in a submitted pass. Multiple Frames in an unsubmitted pass are unsupported:
    -- LÖVR records all compute work before its draws, so a later dispatch would replace the earlier frame's field.
    pass:setShader(held.skyCompute)
    pass:send('backdropResponse', response)
    pass:send('backdropSky', { 0, frame.time, 0, 0 })
    pass:send('backdropMid', settings.palette.mid)
    pass:send('backdropTreble', settings.palette.treble)
    pass:send('overheadImage', held.overheadTexture)
    pass:compute(48, 48, 1)
    held.lastFrame = frame
  end
  pass:setShader(held.skyShader)
  pass:setCullMode(skyCull)
  pass:send('overheadTexture', held.overheadTexture)
  pass:send('overheadSampler', held.overheadSampler)
  local waves, details, ends, live = waveUniforms.prepare(frame.waves, frame.responseStrength)
  local spectrum = frame.spectrum
  local stereo = frame.stereo
  pass:send('backdropSky', { visibility, frame.time, frame.brightness, view })
  pass:send('backdropResponse', response)
  pass:send('backdropZenith', settings.palette.zenith)
  pass:send('backdropHorizon', settings.palette.horizon)
  pass:send('backdropGlint', settings.palette.glint)
  pass:send('backdropTreble', settings.palette.treble)
  pass:send('backdropMid', settings.palette.mid)
  pass:send('backdropWaves', waves)
  pass:send('backdropWaveDetail', details)
  pass:send('backdropWaveCount', live)
  pass:draw(held.sky)
  pass:setCullMode(nil)
  if view ~= 0 then
    return
  end
  pass:setShader(held.curtainShader)
  pass:send('backdropResponse', response)
  pass:send('backdropSpectrum', {
    { spectrum[1], spectrum[2], spectrum[3], spectrum[4] },
    { spectrum[5], spectrum[6], spectrum[7], spectrum[8] },
  })
  pass:send('backdropStereo', {
    { stereo[1], stereo[2], stereo[3], stereo[4] },
    { stereo[5], stereo[6], stereo[7], stereo[8] },
  })
  pass:send('backdropFacing', { facing or 0.5, 0, 0, 0 })
  pass:send('backdropLow', settings.palette.low)
  pass:send('backdropHigh', settings.palette.high)
  pass:send('backdropBass', settings.palette.bass)
  pass:send('backdropMid', settings.palette.mid)
  pass:send('backdropTreble', settings.palette.treble)
  pass:send('backdropWaves', waves)
  pass:send('backdropWaveDetail', details)
  pass:send('backdropWaveCount', live)
  pass:send('backdropWaveEnds', ends)
  for layer = 0, 2 do
    pass:send('backdropScene', { visibility, frame.time, layer, settings.distance })
    pass:send('backdropFocus', LAYER_FOCUS[layer + 1])
    pass:draw(held.curtain)
  end
  pass:setShader(held.wispShader)
  pass:send('backdropScene', { visibility, frame.time, 0, settings.distance })
  pass:send('backdropResponse', response)
  pass:send('backdropLow', settings.palette.low)
  pass:send('backdropHigh', settings.palette.high)
  pass:send('backdropMid', settings.palette.mid)
  pass:send('backdropTreble', settings.palette.treble)
  pass:draw(held.wisps)
end

acquireResources = function(context: plugin.Context, settings: config.Settings): Resources
  local held: Resources? = nil
  context:effect(function(): () -> ()
    local releases: { () -> () } = {}
    local function mesh(data: geometry.Data): Mesh
      local made = lovr.graphics.newMesh(#data.vertices, { storage = 'gpu' })
      table.insert(releases, 1, function(): ()
        made:release()
      end)
      made:setVertices(data.vertices)
      made:setIndices(data.indices)
      return made
    end
    local function compile(vertex: string, fragment: string): Shader
      local made = lovr.graphics.newShader(vertex, fragment, { label = 'desktop/backdrop' })
      table.insert(releases, 1, function(): ()
        made:release()
      end)
      return made
    end
    local ok, failure = pcall(function(): ()
      local data = geometry.build(settings)
      local sky = mesh(data.sky)
      local curtain = mesh(data.curtain)
      local wisps = mesh(data.wisps)
      local skyShader = compile(shader.skyVertex, shader.skyCachedFragment)
      local curtainShader = compile(shader.curtainVertex, shader.curtainFragment)
      local wispShader = compile(shader.wispVertex, shader.wispFragment)
      local skyCompute = lovr.graphics.newShader(shader.skyCompute, { label = 'desktop/backdrop overhead' })
      table.insert(releases, 1, function(): ()
        skyCompute:release()
      end)
      local overheadTexture = lovr.graphics.newTexture(384, 384, {
        type = '2d',
        format = 'rgba16f',
        linear = true,
        samples = 1,
        mipmaps = false,
        usage = { 'sample', 'storage' },
      })
      table.insert(releases, 1, function(): ()
        overheadTexture:release()
      end)
      local overheadSampler = lovr.graphics.newSampler {
        filter = 'linear',
        wrap = 'clamp',
        mipmaprange = { 0, 0 },
      }
      table.insert(releases, 1, function(): ()
        overheadSampler:release()
      end)
      held = {
        sky = sky,
        curtain = curtain,
        wisps = wisps,
        skyShader = skyShader,
        curtainShader = curtainShader,
        wispShader = wispShader,
        skyCompute = skyCompute,
        overheadTexture = overheadTexture,
        overheadSampler = overheadSampler,
        lastFrame = nil,
      }
    end)
    if not ok then
      local cleaned, cleanupFailure = pcall(cleanup.run, 'backdrop acquisition', releases)
      if not cleaned then
        error(tostring(failure) .. '; ' .. tostring(cleanupFailure), 0)
      end
      error(failure, 0)
    end
    return function(): ()
      cleanup.run('backdrop resources', releases)
    end
  end)
  assert(held, 'backdrop: resource acquisition did not complete')
  return held
end

return draw
