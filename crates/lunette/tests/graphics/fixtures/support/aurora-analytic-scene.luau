-- Independently composites the frozen analytic shaders from 28777520 in source wave order.
local config = require '@lunette-plugins/environment/backdrop/config'
local geometry = require '@lunette-plugins/environment/backdrop/private/rendering/geometry'
local model = require '@lunette-plugins/environment/backdrop/private/rendering/model'
local waveUniforms = require '@lunette-plugins/environment/backdrop/private/rendering/wave-uniforms'
local original = require '@lunette-plugins/environment/backdrop/tests/support/band-loop-original-shader'

local reference = {}

export type Keep = <T>(T & { release: (any) -> () }) -> T
export type Renderer = {
  render: (Pass, model.Frame, number, number?, boolean?) -> (),
}

local FOCUS = { { 1.6, 0.6, 0.6, 0 }, { 0.6, 1.6, 0.6, 0 }, { 0.6, 0.6, 1.6, 0 } }
local BAND = { bass = 1, mid = 2, treble = 3 }

function reference.new(settings: config.Settings, keep: Keep): Renderer
  local data = geometry.build(settings)
  local function mesh(surface: geometry.Data): Mesh
    local made = keep(lovr.graphics.newMesh(#surface.vertices, { storage = 'gpu' }))
    made:setVertices(surface.vertices)
    made:setIndices(surface.indices)
    return made
  end
  local meshes = { sky = mesh(data.sky), curtain = mesh(data.curtain), wisps = mesh(data.wisps) }
  local shaders = {
    sky = keep(lovr.graphics.newShader(original.skyVertex, original.skyFragment)),
    curtain = keep(lovr.graphics.newShader(original.curtainVertex, original.curtainFragment)),
    wisps = keep(lovr.graphics.newShader(original.wispVertex, original.wispFragment)),
  }
  return {
    render = function(pass: Pass, frame: model.Frame, opacity: number, view: number?, miniature: boolean?): ()
      local diagnostic = view or 0
      local waves, details = {}, {}
      local count = math.min(#frame.waves, model.MAX_WAVES)
      -- Do not use grouped preparation: this is the frozen shader's chronological accumulation order.
      for index = 1, model.MAX_WAVES do
        local wave = frame.waves[index]
        if index <= count then
          waves[index] = {
            wave.age,
            wave.strength * (1 - wave.age / wave.lifetime) * frame.responseStrength,
            wave.position,
            BAND[wave.band],
          }
          details[index] = waveUniforms.detail(wave)
        else
          waves[index], details[index] = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
        end
      end
      local response = { frame.bass, frame.mid, frame.treble, frame.brightness }
      local palette = settings.palette
      pass:setDepthTest()
      pass:setDepthWrite(false)
      pass:setMaterial(nil)
      pass:setBlendMode('alpha', 'premultiplied')
      pass:setColor(1, 1, 1, 1)
      pass:setCullMode(if miniature then 'back' else nil)
      pass:setShader(shaders.sky)
      pass:send('backdropSky', { opacity, frame.time, frame.brightness, diagnostic })
      pass:send('backdropResponse', response)
      pass:send('backdropZenith', palette.zenith)
      pass:send('backdropHorizon', palette.horizon)
      pass:send('backdropGlint', palette.glint)
      pass:send('backdropTreble', palette.treble)
      pass:send('backdropMid', palette.mid)
      pass:send('backdropWaves', waves)
      pass:send('backdropWaveDetail', details)
      pass:send('backdropWaveCount', count)
      pass:draw(meshes.sky)
      pass:setCullMode(nil)
      if diagnostic ~= 0 then
        return
      end
      pass:setShader(shaders.curtain)
      pass:send('backdropResponse', response)
      pass:send('backdropSpectrum', { { unpack(frame.spectrum, 1, 4) }, { unpack(frame.spectrum, 5, 8) } })
      pass:send('backdropStereo', { { unpack(frame.stereo, 1, 4) }, { unpack(frame.stereo, 5, 8) } })
      pass:send('backdropFacing', { 0.5, 0, 0, 0 })
      pass:send('backdropLow', palette.low)
      pass:send('backdropHigh', palette.high)
      pass:send('backdropBass', palette.bass)
      pass:send('backdropMid', palette.mid)
      pass:send('backdropTreble', palette.treble)
      pass:send('backdropWaves', waves)
      pass:send('backdropWaveDetail', details)
      pass:send('backdropWaveCount', count)
      for layer = 0, 2 do
        pass:send('backdropScene', { opacity, frame.time, layer, settings.distance })
        pass:send('backdropFocus', FOCUS[layer + 1])
        pass:draw(meshes.curtain)
      end
      pass:setShader(shaders.wisps)
      pass:send('backdropScene', { opacity, frame.time, 0, settings.distance })
      pass:send('backdropResponse', response)
      pass:send('backdropLow', palette.low)
      pass:send('backdropHigh', palette.high)
      pass:send('backdropMid', palette.mid)
      pass:send('backdropTreble', palette.treble)
      pass:draw(meshes.wisps)
    end,
  }
end

return reference
