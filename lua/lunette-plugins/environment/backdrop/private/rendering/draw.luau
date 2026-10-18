-- Lazily owns the backdrop's GPU resources and restores every touched pass state on errors.
local plugin = require '@lunette-plugin'
local passState = require '@lunette-plugins/graphics/pass-state'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local config = require '../../config'
local geometry = require './geometry'
local model = require './model'
local selection = require '../selection/selection'
local shader = require './shader'

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
}
local acquireResources: (plugin.Context, config.Settings) -> Resources
local drawScene: (Pass, Resources, config.Settings, model.Frame, number, number?, number, ('front' | 'back')?) -> ()
local BAND_INDEX = table.freeze { bass = 1, mid = 2, treble = 3 } :: { read [model.Band]: number }
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
  pass:setShader(held.skyShader)
  pass:setCullMode(skyCull)
  local response = { frame.bass, frame.mid, frame.treble, frame.brightness }
  local waves: { { number } } = {}
  local details: { { number } } = {}
  -- The model keeps its live waves contiguous from the first slot.
  local live = math.min(#frame.waves, model.MAX_WAVES)
  for index = 1, model.MAX_WAVES do
    local wave = frame.waves[index]
    waves[index] = if wave
      then {
        wave.age,
        wave.strength * (1 - wave.age / wave.lifetime) * frame.responseStrength,
        wave.position,
        BAND_INDEX[wave.band],
      }
      else { 0, 0, 0, 0 }
    details[index] = { if wave then wave.frequency else 0, 0, 0, 0 }
  end
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
      held = {
        sky = mesh(data.sky),
        curtain = mesh(data.curtain),
        wisps = mesh(data.wisps),
        skyShader = compile(shader.skyVertex, shader.skyFragment),
        curtainShader = compile(shader.curtainVertex, shader.curtainFragment),
        wispShader = compile(shader.wispVertex, shader.wispFragment),
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
