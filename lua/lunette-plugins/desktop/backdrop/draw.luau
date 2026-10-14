-- Lazily owns the backdrop's GPU resources and restores every touched pass state on errors.
local plugin = require '@lunette-plugin'
local passState = require '@lunette-plugins/graphics/pass-state'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local config = require './config'
local geometry = require './geometry'
local model = require './model'
local selection = require './selection'
local shader = require './shader'

local draw = {}
export type Renderer = { read render: (Pass, model.Frame, vector, number?) -> () }
type Resources = {
  sky: Mesh,
  curtain: Mesh,
  wisps: Mesh,
  skyShader: Shader,
  curtainShader: Shader,
  wispShader: Shader,
}
local acquireResources: (plugin.Context, config.Settings) -> Resources
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
        pass:setShader(held.skyShader)
        local response = { frame.bass, frame.mid, frame.treble, frame.brightness }
        local waves: { { number } } = {}
        local details: { { number } } = {}
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
        local view = DIAGNOSTIC[diagnostic()]
        pass:send('backdropSky', { frame.visibility, frame.time, frame.brightness, view })
        pass:send('backdropResponse', response)
        pass:send('backdropZenith', settings.palette.zenith)
        pass:send('backdropHorizon', settings.palette.horizon)
        pass:send('backdropGlint', settings.palette.glint)
        pass:send('backdropTreble', settings.palette.treble)
        pass:send('backdropMid', settings.palette.mid)
        pass:send('backdropWaves', waves)
        pass:send('backdropWaveDetail', details)
        pass:draw(held.sky)
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
        for layer = 0, 2 do
          pass:send('backdropScene', { frame.visibility, frame.time, layer, settings.distance })
          pass:send('backdropFocus', LAYER_FOCUS[layer + 1])
          pass:draw(held.curtain)
        end
        pass:setShader(held.wispShader)
        pass:send('backdropScene', { frame.visibility, frame.time, 0, settings.distance })
        pass:send('backdropResponse', response)
        pass:send('backdropLow', settings.palette.low)
        pass:send('backdropHigh', settings.palette.high)
        pass:send('backdropMid', settings.palette.mid)
        pass:send('backdropTreble', settings.palette.treble)
        pass:draw(held.wisps)
      end)
    end,
  }
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
