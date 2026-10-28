-- Compares production shaders with a frozen independent source, on the real indexed backdrop surfaces.
local testing = require '@testing'
local config = require '@lunette-plugins/environment/backdrop/config'
local geometry = require '@lunette-plugins/environment/backdrop/private/rendering/geometry'
local model = require '@lunette-plugins/environment/backdrop/private/rendering/model'
local production = require '@lunette-plugins/environment/backdrop/private/rendering/shader'
local waveUniforms = require '@lunette-plugins/environment/backdrop/private/rendering/wave-uniforms'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local original = require './support/aurora-original-shader'
local render = require './support/render'
local pixels = require './support/pixels'

type NumberRow = { number }
type Angle = { name: string?, direction: vector, up: vector }
type InputOptions = {
  time: number?,
  visibility: number?,
  brightness: number?,
  view: number?,
  layer: number?,
  focus: NumberRow?,
  audio: boolean?,
  facing: number?,
  count: number?,
  band: number?,
  angle: Angle?,
}
type Input = {
  time: number,
  visibility: number,
  brightness: number,
  view: number,
  layer: number,
  focus: NumberRow,
  spectrum: NumberRow,
  stereo: NumberRow,
  response: NumberRow,
  facing: number,
  waves: { NumberRow },
  details: { NumberRow },
  prepared: { NumberRow },
  count: number,
  angle: Angle,
}
type ShaderVersion = 'original' | 'production'
type SurfaceKind = 'sky' | 'curtain'
type ShaderSource = {
  skyVertex: string,
  skyFragment: string,
  curtainVertex: string,
  curtainFragment: string,
}
type ShaderPair = { sky: Shader, curtain: Shader }
type Releaseable = { release: (self: any) -> () }
type Keep = <T>(resource: T & Releaseable) -> T
type Capture = (version: ShaderVersion, kind: SurfaceKind, input: Input) -> pixels.ImageData
type Compare = (kind: SurfaceKind, input: Input, label: string) -> ()
type Scenario = InputOptions & { name: string }
type Totals = { count: number, maximum: number, mean: number }

local test = testing.suite()

local WIDTH, HEIGHT = 96, 64
local MAX_ERROR, MEAN_ERROR = 1e-4, 1e-5
local ZERO = { 0, 0, 0, 0, 0, 0, 0, 0 }
local SPECTRUM = { 0.8, 0.35, 0.6, 0.9, 0.25, 0.7, 0.45, 1 }
local STEREO = { -0.8, 0.2, -0.3, 0.9, -0.1, 0.4, -0.45, 0.8 }
local LAYER_FOCUS = { { 1.6, 0.6, 0.6, 0 }, { 0.6, 1.6, 0.6, 0 }, { 0.6, 0.6, 1.6, 0 } }
local ANGLES: { Angle } = {
  { name = 'horizon', direction = vector.pack(0, 0, -1), up = vector.pack(0, 1, 0) },
  { name = 'up', direction = vector.pack(0, 1, 0), up = vector.pack(0, 0, 1) },
  { name = 'down', direction = vector.pack(0, -1, 0), up = vector.pack(0, 0, 1) },
  { name = 'side', direction = vector.pack(1, 0, 0), up = vector.pack(0, 1, 0) },
}
local CURTAIN_ANGLE = { direction = vector.pack(0, 0.42, -1), up = vector.pack(0, 1, 0) }

local function withResources<T>(run: (keep: Keep) -> T): T
  local releases: { () -> () } = {}
  local function keep<T>(resource: T & Releaseable): T
    table.insert(releases, 1, function(): ()
      resource:release()
    end)
    return resource
  end
  local ok, result = pcall(run, keep)
  local closed, closeFailure = pcall(cleanup.run, 'aurora pixel oracle', releases)
  if not ok then
    error(tostring(result) .. (if closed then '' else '\n' .. tostring(closeFailure)), 0)
  end
  assert(closed, closeFailure)
  return result
end

local function waveInputs(count: number, singleBand: number?): ({ NumberRow }, { NumberRow }, { NumberRow })
  local waves, details, prepared = {}, {}, {}
  local bands = { 'bass', 'mid', 'treble' }
  local ages = { 0, 0.02, 0.079, 0.08, 0.081, 0.3, 0.7 }
  for index = 1, model.MAX_WAVES do
    if index <= count then
      local band = singleBand or (index - 1) % 3 + 1
      if count == model.MAX_WAVES then
        band = if index <= model.wavePools.bass
          then 1
          elseif index <= model.wavePools.bass + model.wavePools.mid then 2
          else 3
      end
      local fraction = (index - 1) / math.max(count - 1, 1)
      -- Ages straddle the treble rise and exercise fresh and decaying fronts; positions also cross the UV seam.
      local age = if count == 1 then 0.08 else ages[(index - 1) % #ages + 1]
      local position = if count <= 3 then 0.46 + index * 0.02 else (0.98 + fraction * 0.91) % 1
      waves[index] = { age, 0.95 - fraction * 0.6, position, band }
      local frequency = if count == 1 then (band - 1) / 2 else fraction
      details[index] = { frequency, 0, 0, 0 }
      prepared[index] = waveUniforms.detail {
        age = age,
        strength = waves[index][2],
        position = position,
        band = bands[band],
        lifetime = model.waveLifetimes[bands[band]],
        frequency = frequency,
      }
    else
      -- Nonzero inactive slots catch implementations that accidentally consume more than the live prefix.
      waves[index], details[index] = { 0.1, 1, 0.5, 3 }, { 1, 0, 0, 0 }
      prepared[index] = { 1, 0.016, 0.74, 0.45 }
    end
  end
  return waves, details, prepared
end

local function inputs(options: InputOptions): Input
  local count = options.count or 0
  local waves, details, prepared = waveInputs(count, options.band)
  return {
    time = options.time or 0,
    visibility = options.visibility or 1,
    brightness = options.brightness or 1,
    view = options.view or 0,
    layer = options.layer or 0,
    focus = options.focus or LAYER_FOCUS[(options.layer or 0) + 1],
    spectrum = if options.audio then SPECTRUM else ZERO,
    stereo = if options.audio then STEREO else ZERO,
    response = if options.audio then { 0.8, 0.9, 1, options.brightness or 1 } else { 0, 0, 0, options.brightness or 1 },
    facing = options.facing or 0.5,
    waves = waves,
    details = details,
    prepared = prepared,
    count = count,
    angle = options.angle or CURTAIN_ANGLE,
  }
end

local function withOracle(run: (compare: Compare) -> ()): ()
  withResources(function(keep: Keep): ()
    local settings = config.schema.parse {}
    local data = geometry.build(settings)
    local function mesh(surface: geometry.Data): Mesh
      local made = keep(lovr.graphics.newMesh(#surface.vertices, { storage = 'gpu' }))
      made:setVertices(surface.vertices)
      made:setIndices(surface.indices)
      return made
    end
    local meshes = { sky = mesh(data.sky), curtain = mesh(data.curtain) }
    local function compile(source: ShaderSource): ShaderPair
      return {
        sky = keep(lovr.graphics.newShader(source.skyVertex, source.skyFragment)),
        curtain = keep(lovr.graphics.newShader(source.curtainVertex, source.curtainFragment)),
      }
    end
    local shaders = { original = compile(original), production = compile(production) }
    local texture = keep(lovr.graphics.newTexture(WIDTH, HEIGHT, {
      format = 'rgba32f',
      linear = true,
      samples = 1,
      mipmaps = false,
      usage = { 'render', 'transfer' },
    }))
    local pass = keep(lovr.graphics.newPass { texture = texture, depth = false, samples = 1 })
    local function capture(version: ShaderVersion, kind: SurfaceKind, input: Input): pixels.ImageData
      pass:reset()
      pass:setCanvas { texture = texture, depth = false, samples = 1 }
      pass:setClear(0, 0, 0, 0)
      pass:setProjection('perspective', math.rad(80), WIDTH / HEIGHT, 0.1, 0)
      pass:setViewPose(1, lovr.math.mat4():target(vector.zero, input.angle.direction, input.angle.up))
      pass:setDepthTest()
      pass:setDepthWrite(false)
      pass:setCullMode(nil)
      pass:setBlendMode(nil)
      pass:setColor(1, 1, 1, 1)
      pass:setShader(shaders[version][kind])
      pass:send('backdropResponse', input.response)
      pass:send('backdropWaves', input.waves)
      pass:send('backdropWaveDetail', if version == 'production' then input.prepared else input.details)
      pass:send('backdropWaveCount', input.count)
      if kind == 'sky' then
        pass:send('backdropSky', { input.visibility, input.time, input.brightness, input.view })
        pass:send('backdropZenith', settings.palette.zenith)
        pass:send('backdropHorizon', settings.palette.horizon)
        pass:send('backdropGlint', settings.palette.glint)
      else
        pass:send('backdropScene', { input.visibility, input.time, input.layer, settings.distance })
        pass:send('backdropFocus', input.focus)
        pass:send('backdropSpectrum', { { unpack(input.spectrum, 1, 4) }, { unpack(input.spectrum, 5, 8) } })
        local sides = input.stereo
        if input.facing == 0.125 then
          sides = table.clone(sides)
          for index, value in sides do
            sides[index] = -value
          end
        end
        pass:send('backdropStereo', { { unpack(sides, 1, 4) }, { unpack(sides, 5, 8) } })
        pass:send('backdropFacing', { input.facing, 0, 0, 0 })
        pass:send('backdropLow', settings.palette.low)
        pass:send('backdropHigh', settings.palette.high)
        pass:send('backdropBass', settings.palette.bass)
      end
      pass:send('backdropMid', settings.palette.mid)
      pass:send('backdropTreble', settings.palette.treble)
      pass:draw(meshes[kind])
      return withResources(function(keepImage: Keep): pixels.ImageData
        local image = keepImage(render.read(texture, pass))
        return pixels.read(image)
      end)
    end
    local totals: Totals = { count = 0, maximum = 0, mean = 0 }
    local function compare(kind: SurfaceKind, input: Input, label: string): ()
      local expected = capture('original', kind, input)
      local actual = capture('production', kind, input)
      assert(actual.width == expected.width and actual.height == expected.height, label .. ': image dimensions differ')
      local maximum, sum, nonblank = 0, 0, 0
      for index, p in expected.values do
        local q = actual.values[index]
        for _, channel in { 'r', 'g', 'b', 'a' } do
          local a, b = p[channel], q[channel]
          assert(a == a and math.abs(a) < math.huge, label .. ': original contains a non-finite channel')
          assert(b == b and math.abs(b) < math.huge, label .. ': production contains a non-finite channel')
          local delta = math.abs(a - b)
          maximum = math.max(maximum, delta)
          sum += delta
        end
        nonblank += if p.r + p.g + p.b > 1e-7 then 1 else 0
        if kind == 'sky' then
          local alpha = if input.view == 0 then input.visibility else 1
          assert(math.abs(p.a - alpha) <= 1e-6, label .. ': the sky reference does not cover the target')
        end
      end
      local mean = sum / (#expected.values * 4)
      assert(
        maximum <= MAX_ERROR and mean <= MEAN_ERROR,
        string.format(
          '%s: RGBA max %.9g (limit %.9g), mean %.9g (limit %.9g)',
          label,
          maximum,
          MAX_ERROR,
          mean,
          MEAN_ERROR
        )
      )
      local belowHorizon = kind == 'sky'
        and input.angle.name == 'down'
        and (input.view == 2 or input.view == 4 or input.view == 5)
      if belowHorizon or (input.brightness == 0 and input.view == 0) then
        assert(nonblank == 0, label .. ': the reference should have no emitted light')
      else
        assert(nonblank > 0, label .. ': the reference has no visible pixels')
      end
      totals.count += 1
      totals.maximum = math.max(totals.maximum, maximum)
      totals.mean = math.max(totals.mean, mean)
    end
    run(compare)
    print('aurora pixel oracle', totals.count, 'worst RGBA max', totals.maximum, 'worst RGBA mean', totals.mean)
  end)
end

test('the sky matches the original at all view stages and clock extremes', function(): ()
  withOracle(function(compare: Compare): ()
    for clock, time in { 0, 123, 4095 } do
      for _, angle in ANGLES do
        for view = 0, 5 do
          local input = inputs {
            time = time,
            angle = angle,
            view = view,
            audio = clock ~= 1,
            count = if clock == 1 then 0 elseif clock == 2 then 3 else model.MAX_WAVES,
          }
          compare('sky', input, string.format('sky/%s/time-%d/view-%d', angle.name, time, view))
        end
      end
    end
    for _, angle in ANGLES do
      for _, view in { 0, 5 } do
        compare(
          'sky',
          inputs {
            time = 123,
            angle = angle,
            view = view,
            audio = true,
            count = model.MAX_WAVES,
            brightness = 0,
            visibility = 0.35,
          },
          string.format('sky/%s/zero-brightness/view-%d', angle.name, view)
        )
      end
    end
  end)
end)

test('each isolated curtain layer matches for spectrum, onsets, focus, and visibility', function(): ()
  local scenarios: { Scenario } = {
    { name = 'silence', time = 0 },
    { name = 'spectrum-stereo', time = 123, audio = true },
    { name = 'mirrored-stereo-facing', time = 4095, audio = true, facing = 0.125 },
    { name = 'bass-onset', time = 0, count = 1, band = 1 },
    { name = 'mid-onset', time = 123, count = 1, band = 2 },
    { name = 'treble-onset', time = 4095, count = 1, band = 3 },
    { name = 'one-onset-per-band', time = 123, audio = true, count = 3 },
    { name = 'full-wave-pool', time = 4095, audio = true, count = model.MAX_WAVES },
    { name = 'zero-focus', time = 123, audio = true, count = model.MAX_WAVES, focus = { 0, 0, 0, 0 } },
    {
      name = 'quiet-focus-partial-visibility',
      time = 0,
      audio = true,
      count = model.MAX_WAVES,
      focus = { 0.6, 0.6, 0.6, 0 },
      visibility = 0.35,
    },
    { name = 'full-focus', time = 123, audio = true, count = model.MAX_WAVES, focus = { 1.6, 1.6, 1.6, 0 } },
    {
      name = 'zero-brightness-mixed-focus',
      time = 4095,
      audio = true,
      count = model.MAX_WAVES,
      focus = { 0, 0.6, 1.6, 0 },
      visibility = 0.35,
      brightness = 0,
    },
  }
  withOracle(function(compare: Compare): ()
    for layer = 0, 2 do
      for _, scenario in scenarios do
        local options = table.clone(scenario)
        options.layer = layer
        compare('curtain', inputs(options), string.format('curtain/layer-%d/%s', layer, scenario.name))
      end
    end
  end)
end)

return test
