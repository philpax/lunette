-- Isolates curtain approximation against frozen source-order shaders while both composites use the maintained sky.
local config = require '@lunette-plugins/environment/backdrop/config'
local geometry = require '@lunette-plugins/environment/backdrop/private/rendering/geometry'
local model = require '@lunette-plugins/environment/backdrop/private/rendering/model'
local waveUniforms = require '@lunette-plugins/environment/backdrop/private/rendering/wave-uniforms'
local sky = require '@lunette-plugins/environment/backdrop/private/rendering/shader'
local original = require '@lunette-plugins/environment/backdrop/tests/support/band-loop-original-shader'
local passState = require '@lunette-plugins/graphics/pass-state'

local reference = {}
export type Keep = <T>(T & { release: (any) -> () }) -> T
export type Renderer = {
  render: (Pass, model.Frame, number, number, number, boolean?) -> (),
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
    sky = keep(lovr.graphics.newShader(sky.skyVertex, sky.skyCachedFragment)),
    curtain = keep(lovr.graphics.newShader(original.curtainVertex, original.curtainFragment)),
    wisps = keep(lovr.graphics.newShader(original.wispVertex, original.wispFragment)),
    compute = keep(lovr.graphics.newShader(sky.skyCompute)),
  }
  local overhead = keep(lovr.graphics.newTexture(384, 384, {
    type = '2d',
    format = 'rgba16f',
    linear = true,
    samples = 1,
    mipmaps = false,
    usage = { 'sample', 'storage' },
  }))
  local sampler = keep(lovr.graphics.newSampler { filter = 'linear', wrap = 'clamp', mipmaprange = { 0, 0 } })
  local lastFrame: model.Frame? = nil
  return {
    render = function(
      pass: Pass,
      frame: model.Frame,
      opacity: number,
      view: number,
      facing: number,
      miniature: boolean?
    ): ()
      if opacity <= 0 then
        return
      end
      passState.withRestore(pass, function(): ()
        local waves, details = {}, {}
        local count = math.min(#frame.waves, model.MAX_WAVES)
        -- The oracle neither groups waves nor imports the production curtain equations or compute shader.
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
        if view == 0 and frame.brightness > 0 and lastFrame ~= frame then
          pass:setShader(shaders.compute)
          pass:send('backdropResponse', response)
          pass:send('backdropSky', { 0, frame.time, 0, 0 })
          pass:send('backdropMid', palette.mid)
          pass:send('backdropTreble', palette.treble)
          pass:send('overheadImage', overhead)
          pass:compute(48, 48, 1)
          lastFrame = frame
        end
        pass:setDepthTest()
        pass:setDepthWrite(false)
        pass:setMaterial(nil)
        pass:setBlendMode('alpha', 'premultiplied')
        pass:setColor(1, 1, 1, 1)
        pass:setCullMode(if miniature then 'back' else nil)
        pass:setShader(shaders.sky)
        pass:send('overheadTexture', overhead)
        pass:send('overheadSampler', sampler)
        pass:send('backdropSky', { opacity, frame.time, frame.brightness, view })
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
        if view ~= 0 then
          return
        end
        pass:setShader(shaders.curtain)
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
      end)
    end,
  }
end

return reference
