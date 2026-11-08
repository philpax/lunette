-- Lazily owns the backdrop's GPU resources and restores every touched pass state on errors.
local plugin = require '@lunette-plugin'
local frameContract = require '@lunette-contracts/frame'
local passState = require '@lunette-plugins/graphics/pass-state'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local config = require '../../config'
local geometry = require './geometry'
local halfResolution = require './half-resolution'
local model = require './model'
local selection = require '../selection/selection'
local shader = require './shader'
local waveUniforms = require './wave-uniforms'

local draw = {}
export type Renderer = {
  read render: (Pass, model.Frame, vector, number?) -> frameContract.DrawPasses?,
  -- Draws the backdrop about the pass's origin, scaled to `radius` metres and seen from outside. The model remains
  -- visible independently of the backdrop's visibility and diagnostic view.
  read miniature: (Pass, model.Frame, number, number?, number) -> (),
}
type Destination = 'main' | 'preparation'
type RecordedField = {
  read frame: model.Frame,
  read destination: Destination,
  read pass: Pass,
  read draws: number,
  read computes: number,
}
type Input = {
  read frame: model.Frame,
  read response: { number },
  read waves: { { number } },
  read details: { { number } },
  read ends: { number },
  read live: number,
}
type PendingFields = { sky: boolean, onset: boolean }
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
  curtainCompute: Shader,
  onsetPulses: Texture,
  onsetZones: Texture,
  onsetSampler: Sampler,
  skyField: RecordedField?,
  onsetField: RecordedField?,
}
local acquireResources: (plugin.Context, config.Settings) -> Resources
local prepareInput: (model.Frame) -> Input
local sceneState: (Pass) -> ()
local record: (Pass, Resources, Input, Destination, (PendingFields) -> ()) -> ()
local prepareFields: (Pass, Resources, config.Settings, Input, Destination, number, PendingFields) -> ()
local reusable: (RecordedField?, model.Frame, Destination, Pass) -> boolean
local drawSky: (Pass, Resources, config.Settings, Input, number, number, ('front' | 'back')?) -> ()
local drawCurtains: (Pass, Resources, config.Settings, Input, number, number?) -> ()
local drawWisps: (Pass, Resources, config.Settings, Input, number) -> ()
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
  local lowResolution = halfResolution.new(context)
  return table.freeze {
    render = function(pass: Pass, frame: model.Frame, headPosition: vector, facing: number?): frameContract.DrawPasses?
      if frame.visibility <= 0 or not context:active() then
        return nil
      end
      local view = DIAGNOSTIC[diagnostic()]
      local held: Resources = resources or acquireResources(context, settings)
      resources = held
      local input = prepareInput(frame)
      -- Preparation resets its owned pass even for the same Frame, invalidating its recorded field dispatches.
      if held.skyField and held.skyField.destination == 'preparation' then
        held.skyField = nil
      end
      if held.onsetField and held.onsetField.destination == 'preparation' then
        held.onsetField = nil
      end
      local target = if view == 0 then lowResolution.prepare(pass) else nil
      local computePass = if target then target.pass else pass
      local destination: Destination = if target then 'preparation' else 'main'
      record(computePass, held, input, destination, function(pending: PendingFields): ()
        passState.withRestore(pass, function(): ()
          pass:origin()
          pass:translate(headPosition)
          sceneState(pass)
          if target then
            local preparation = target.pass
            passState.withRestore(preparation, function(): ()
              preparation:origin()
              preparation:translate(headPosition)
              sceneState(preparation)
              prepareFields(preparation, held, settings, input, destination, view, pending)
              drawCurtains(preparation, held, settings, input, frame.visibility, facing)
            end)
          else
            prepareFields(pass, held, settings, input, destination, view, pending)
          end
          drawSky(pass, held, settings, input, frame.visibility, view, nil)
          if view ~= 0 then
            return
          end
          if target then
            lowResolution.composite(pass, target)
          else
            drawCurtains(pass, held, settings, input, frame.visibility, facing)
          end
          drawWisps(pass, held, settings, input, frame.visibility)
        end)
      end)
      return if target then { target.pass } else nil
    end,
    miniature = function(pass: Pass, frame: model.Frame, radius: number, facing: number?, opacity: number): ()
      if opacity <= 0 or not context:active() then
        return
      end
      local held: Resources = resources or acquireResources(context, settings)
      resources = held
      local input = prepareInput(frame)
      record(pass, held, input, 'main', function(pending: PendingFields): ()
        passState.withRestore(pass, function(): ()
          pass:scale(radius / settings.distance)
          pass:setDepthWrite(false)
          pass:setMaterial(nil)
          pass:setBlendMode('alpha', 'premultiplied')
          pass:setColor(1, 1, 1, 1)
          prepareFields(pass, held, settings, input, 'main', 0, pending)
          -- Culling the near half's back faces leaves the far half as the miniature's backdrop.
          drawSky(pass, held, settings, input, opacity, 0, 'back')
          drawCurtains(pass, held, settings, input, opacity, facing)
          drawWisps(pass, held, settings, input, opacity)
        end)
      end)
    end,
  }
end

prepareInput = function(frame: model.Frame): Input
  local waves, details, ends, live = waveUniforms.prepare(frame.waves, frame.responseStrength)
  return {
    frame = frame,
    response = { frame.bass, frame.mid, frame.treble, frame.brightness },
    waves = waves,
    details = details,
    ends = ends,
    live = live,
  }
end

sceneState = function(pass: Pass): ()
  pass:setDepthTest()
  pass:setDepthWrite(false)
  pass:setCullMode(nil)
  pass:setMaterial(nil)
  pass:setBlendMode('alpha', 'premultiplied')
  pass:setColor(1, 1, 1, 1)
end

record = function(pass: Pass, held: Resources, input: Input, destination: Destination, body: (PendingFields) -> ()): ()
  local pending = { sky = false, onset = false }
  local ok, result = pcall(function(): { read draws: number, read computes: number }
    body(pending)
    return pass:getStats()
  end)
  local failure = if ok then nil else result
  if not ok then
    if destination == 'preparation' then
      held.skyField, held.onsetField = nil, nil
      error(failure, 0)
    end
    -- A failed direct draw leaves successful dispatches in its caller's pass; preparation is not returned on errors.
    local inspected, stats = pcall(function(): { read draws: number, read computes: number }
      return pass:getStats()
    end)
    if not inspected then
      held.skyField, held.onsetField = nil, nil
      error(tostring(failure) .. '; ' .. tostring(stats), 0)
    end
    result = stats
  end
  local completed: RecordedField = {
    frame = input.frame,
    destination = destination,
    pass = pass,
    draws = result.draws,
    computes = result.computes,
  }
  if pending.sky then
    held.skyField = completed
  end
  if pending.onset then
    held.onsetField = completed
  end
  if not ok then
    error(failure, 0)
  end
end

reusable = function(cached: RecordedField?, frame: model.Frame, destination: Destination, pass: Pass): boolean
  if not cached or cached.frame ~= frame then
    return false
  end
  -- A miniature can record main-pass compute first, but that pass submits after the curtain preparation.
  if destination == 'preparation' and cached.destination ~= 'preparation' then
    return false
  end
  if cached.pass ~= pass then
    return true
  end
  -- Counts catch an empty reset, but the public API exposes no recording generation for arbitrary external resets.
  local stats = pass:getStats()
  return stats.draws >= cached.draws and stats.computes >= cached.computes
end

prepareFields = function(
  pass: Pass,
  held: Resources,
  settings: config.Settings,
  input: Input,
  destination: Destination,
  view: number,
  pending: PendingFields
): ()
  local frame = input.frame
  -- Multiple Frames in one unsubmitted pass are unsupported: LÖVR records all compute work before its draws.
  if view == 0 and frame.brightness > 0 and not reusable(held.skyField, frame, destination, pass) then
    held.skyField = nil
    pass:setShader(held.skyCompute)
    pass:send('backdropResponse', input.response)
    pass:send('backdropSky', { 0, frame.time, 0, 0 })
    pass:send('backdropMid', settings.palette.mid)
    pass:send('backdropTreble', settings.palette.treble)
    pass:send('overheadImage', held.overheadTexture)
    pass:compute(48, 48, 1)
    pending.sky = true
  end
  if
    view == 0
    and frame.brightness > 0
    and input.live > 8
    and not reusable(held.onsetField, frame, destination, pass)
  then
    held.onsetField = nil
    pass:setShader(held.curtainCompute)
    pass:send('backdropWaves', input.waves)
    pass:send('backdropWaveDetail', input.details)
    pass:send('backdropWaveCount', input.live)
    pass:send('backdropWaveEnds', input.ends)
    pass:send('onsetPulsesImage', held.onsetPulses)
    pass:send('onsetZonesImage', held.onsetZones)
    pass:compute(64, 8, 1)
    pending.onset = true
  end
end

drawSky = function(
  pass: Pass,
  held: Resources,
  settings: config.Settings,
  input: Input,
  visibility: number,
  view: number,
  skyCull: ('front' | 'back')?
): ()
  local frame = input.frame
  pass:setShader(held.skyShader)
  pass:setCullMode(skyCull)
  pass:send('overheadTexture', held.overheadTexture)
  pass:send('overheadSampler', held.overheadSampler)
  pass:send('backdropSky', { visibility, frame.time, frame.brightness, view })
  pass:send('backdropResponse', input.response)
  pass:send('backdropZenith', settings.palette.zenith)
  pass:send('backdropHorizon', settings.palette.horizon)
  pass:send('backdropGlint', settings.palette.glint)
  pass:send('backdropTreble', settings.palette.treble)
  pass:send('backdropMid', settings.palette.mid)
  pass:send('backdropWaves', input.waves)
  pass:send('backdropWaveDetail', input.details)
  pass:send('backdropWaveCount', input.live)
  pass:draw(held.sky)
  pass:setCullMode(nil)
end

drawCurtains = function(
  pass: Pass,
  held: Resources,
  settings: config.Settings,
  input: Input,
  visibility: number,
  facing: number?
): ()
  local frame = input.frame
  local spectrum, stereo = frame.spectrum, frame.stereo
  pass:setShader(held.curtainShader)
  pass:send('onsetPulses', held.onsetPulses)
  pass:send('onsetZones', held.onsetZones)
  pass:send('onsetSampler', held.onsetSampler)
  pass:send('backdropResponse', input.response)
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
  pass:send('backdropWaves', input.waves)
  pass:send('backdropWaveDetail', input.details)
  pass:send('backdropWaveCount', input.live)
  pass:send('backdropWaveEnds', input.ends)
  for layer = 0, 2 do
    pass:send('backdropScene', { visibility, frame.time, layer, settings.distance })
    pass:send('backdropFocus', LAYER_FOCUS[layer + 1])
    pass:draw(held.curtain)
  end
end

drawWisps = function(pass: Pass, held: Resources, settings: config.Settings, input: Input, visibility: number): ()
  local frame = input.frame
  pass:setShader(held.wispShader)
  pass:send('backdropScene', { visibility, frame.time, 0, settings.distance })
  pass:send('backdropResponse', input.response)
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
      local curtainShader = compile(shader.curtainVertex, shader.curtainCachedFragment)
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
      local curtainCompute = lovr.graphics.newShader(shader.curtainCompute, { label = 'desktop/backdrop onsets' })
      table.insert(releases, 1, function(): ()
        curtainCompute:release()
      end)
      local function onsetTexture(height: number): Texture
        local made = lovr.graphics.newTexture(512, height, {
          type = '2d',
          format = 'rgba16f',
          linear = true,
          samples = 1,
          mipmaps = false,
          usage = { 'sample', 'storage' },
        })
        table.insert(releases, 1, function(): ()
          made:release()
        end)
        return made
      end
      local onsetPulses = onsetTexture(1)
      local onsetZones = onsetTexture(64)
      local onsetSampler = lovr.graphics.newSampler {
        filter = 'linear',
        wrap = { 'repeat', 'clamp', 'clamp' },
        mipmaprange = { 0, 0 },
      }
      table.insert(releases, 1, function(): ()
        onsetSampler:release()
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
        curtainCompute = curtainCompute,
        onsetPulses = onsetPulses,
        onsetZones = onsetZones,
        onsetSampler = onsetSampler,
        skyField = nil,
        onsetField = nil,
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
