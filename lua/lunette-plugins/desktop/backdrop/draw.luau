-- Lazily owns the backdrop's GPU resources and restores every touched pass state on errors.
local plugin = require '@lunette-plugin'
local passState = require '@lunette-plugins/pass-state'
local cleanup = require '@lunette-plugins/cleanup'
local config = require './config'
local geometry = require './geometry'
local model = require './model'
local shader = require './shader'

local draw = {}
export type Renderer = { read render: (Pass, model.Frame, vector) -> () }
type Resources = { sky: Mesh, curtain: Mesh, skyShader: Shader, curtainShader: Shader }
local acquireResources: (plugin.Context, config.Settings) -> Resources

function draw.new(context: plugin.Context, settings: config.Settings): Renderer
  local resources: Resources? = nil
  return table.freeze {
    render = function(pass: Pass, frame: model.Frame, headPosition: vector): ()
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
        pass:send('backdropSky', { frame.visibility, frame.time, frame.brightness, 0 })
        pass:send('backdropZenith', settings.palette.zenith)
        pass:send('backdropHorizon', settings.palette.horizon)
        pass:send('backdropGlint', settings.palette.glint)
        pass:draw(held.sky)
        pass:setShader(held.curtainShader)
        pass:send('backdropResponse', { frame.bass, frame.mid, frame.treble, frame.brightness })
        pass:send('backdropLow', settings.palette.low)
        pass:send('backdropHigh', settings.palette.high)
        local waves: { { number } } = {}
        for index = 1, 8 do
          local wave = frame.waves[index]
          waves[index] = if wave
            then { wave.age, wave.strength * (1 - wave.age / 3) * frame.responseStrength, wave.position, 0 }
            else { 0, 0, 0, 0 }
        end
        pass:send('backdropWaves', waves)
        for layer = 0, 2 do
          pass:send('backdropScene', { frame.visibility, frame.time, layer, settings.distance })
          pass:draw(held.curtain)
        end
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
        skyShader = compile(shader.skyVertex, shader.skyFragment),
        curtainShader = compile(shader.curtainVertex, shader.curtainFragment),
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
