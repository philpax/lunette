-- Preserves the direct sky, three curtains, and wisps composition from 7d6e9432 independently of draw.render.
local config = require '@lunette-plugins/environment/backdrop/config'
local geometry = require '@lunette-plugins/environment/backdrop/private/rendering/geometry'
local model = require '@lunette-plugins/environment/backdrop/private/rendering/model'
local shader = require '@lunette-plugins/environment/backdrop/private/rendering/shader'
local waveUniforms = require '@lunette-plugins/environment/backdrop/private/rendering/wave-uniforms'
local passState = require '@lunette-plugins/graphics/pass-state'

local reference = {}
export type Keep = <T>(T & { release: (any) -> () }) -> T
export type Renderer = {
  render: (Pass, model.Frame, number, number, boolean?) -> (),
}
local FOCUS = { { 1.6, 0.6, 0.6, 0 }, { 0.6, 1.6, 0.6, 0 }, { 0.6, 0.6, 1.6, 0 } }

function reference.new(settings: config.Settings, keep: Keep): Renderer
  local function mesh(surface: geometry.Data): Mesh
    local made = keep(lovr.graphics.newMesh(#surface.vertices, { storage = 'gpu' }))
    made:setVertices(surface.vertices)
    made:setIndices(surface.indices)
    return made
  end
  local function field(width: number, height: number): Texture
    return keep(lovr.graphics.newTexture(width, height, {
      type = '2d',
      format = 'rgba16f',
      linear = true,
      samples = 1,
      mipmaps = false,
      usage = { 'sample', 'storage' },
    }))
  end
  local data = geometry.build(settings)
  local meshes = { sky = mesh(data.sky), curtain = mesh(data.curtain), wisps = mesh(data.wisps) }
  local shaders = {
    sky = keep(lovr.graphics.newShader(shader.skyVertex, shader.skyCachedFragment)),
    curtain = keep(lovr.graphics.newShader(shader.curtainVertex, shader.curtainCachedFragment)),
    wisps = keep(lovr.graphics.newShader(shader.wispVertex, shader.wispFragment)),
    skyCompute = keep(lovr.graphics.newShader(shader.skyCompute)),
    curtainCompute = keep(lovr.graphics.newShader(shader.curtainCompute)),
  }
  local overhead, pulses, zones = field(384, 384), field(512, 1), field(512, 64)
  local overheadSampler = keep(lovr.graphics.newSampler { filter = 'linear', wrap = 'clamp', mipmaprange = { 0, 0 } })
  local onsetSampler = keep(lovr.graphics.newSampler {
    filter = 'linear',
    wrap = { 'repeat', 'clamp', 'clamp' },
    mipmaprange = { 0, 0 },
  })
  local skyFrame: model.Frame? = nil
  local onsetFrame: model.Frame? = nil
  return {
    render = function(pass: Pass, frame: model.Frame, opacity: number, facing: number, miniature: boolean?): ()
      if opacity <= 0 then
        return
      end
      passState.withRestore(pass, function(): ()
        local response = { frame.bass, frame.mid, frame.treble, frame.brightness }
        local waves, details, ends, live = waveUniforms.prepare(frame.waves, frame.responseStrength)
        local palette = settings.palette
        if frame.brightness > 0 and skyFrame ~= frame then
          pass:setShader(shaders.skyCompute)
          pass:send('backdropResponse', response)
          pass:send('backdropSky', { 0, frame.time, 0, 0 })
          pass:send('backdropMid', palette.mid)
          pass:send('backdropTreble', palette.treble)
          pass:send('overheadImage', overhead)
          pass:compute(48, 48, 1)
          skyFrame = frame
        end
        if frame.brightness > 0 and live > 8 and onsetFrame ~= frame then
          pass:setShader(shaders.curtainCompute)
          pass:send('backdropWaves', waves)
          pass:send('backdropWaveDetail', details)
          pass:send('backdropWaveCount', live)
          pass:send('backdropWaveEnds', ends)
          pass:send('onsetPulsesImage', pulses)
          pass:send('onsetZonesImage', zones)
          pass:compute(64, 8, 1)
          onsetFrame = frame
        end
        pass:setDepthTest()
        pass:setDepthWrite(false)
        pass:setMaterial(nil)
        pass:setBlendMode('alpha', 'premultiplied')
        pass:setColor(1, 1, 1, 1)
        pass:setCullMode(if miniature then 'back' else nil)
        pass:setShader(shaders.sky)
        pass:send('overheadTexture', overhead)
        pass:send('overheadSampler', overheadSampler)
        pass:send('backdropSky', { opacity, frame.time, frame.brightness, 0 })
        pass:send('backdropResponse', response)
        pass:send('backdropZenith', palette.zenith)
        pass:send('backdropHorizon', palette.horizon)
        pass:send('backdropGlint', palette.glint)
        pass:send('backdropTreble', palette.treble)
        pass:send('backdropMid', palette.mid)
        pass:send('backdropWaves', waves)
        pass:send('backdropWaveDetail', details)
        pass:send('backdropWaveCount', live)
        pass:draw(meshes.sky)
        pass:setCullMode(nil)
        pass:setShader(shaders.curtain)
        pass:send('onsetPulses', pulses)
        pass:send('onsetZones', zones)
        pass:send('onsetSampler', onsetSampler)
        pass:send('backdropResponse', response)
        pass:send('backdropSpectrum', { { unpack(frame.spectrum, 1, 4) }, { unpack(frame.spectrum, 5, 8) } })
        pass:send('backdropStereo', { { unpack(frame.stereo, 1, 4) }, { unpack(frame.stereo, 5, 8) } })
        pass:send('backdropFacing', { facing, 0, 0, 0 })
        pass:send('backdropLow', palette.low)
        pass:send('backdropHigh', palette.high)
        pass:send('backdropBass', palette.bass)
        pass:send('backdropMid', palette.mid)
        pass:send('backdropTreble', palette.treble)
        pass:send('backdropWaves', waves)
        pass:send('backdropWaveDetail', details)
        pass:send('backdropWaveCount', live)
        pass:send('backdropWaveEnds', ends)
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
      end)
    end,
  }
end

return reference
