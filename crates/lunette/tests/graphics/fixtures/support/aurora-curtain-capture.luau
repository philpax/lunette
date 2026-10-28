-- Owns real renderer fixtures, layered readbacks, and independent image-error and update measurements.
local testing = require '@testing'
local plugin = require '@lunette-plugin'
local config = require '@lunette-plugins/environment/backdrop/config'
local draw = require '@lunette-plugins/environment/backdrop/private/rendering/draw'
local model = require '@lunette-plugins/environment/backdrop/private/rendering/model'
local selection = require '@lunette-plugins/environment/backdrop/private/selection/selection'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local reference = require './aurora-curtain-scene'
local pixels = require './pixels'

local capture = {}
export type Scenario = {
  name: string,
  time: number?,
  count: number?,
  age: number?,
  shift: number?,
  strength: number?,
  band: model.Band?,
  reverse: boolean?,
  seam: boolean?,
  brightness: number?,
  visibility: number?,
  facing: number?,
  angle: string?,
  view: number?,
  miniature: boolean?,
  shared: boolean?,
  stereo: boolean?,
}
export type Pair = { actual: pixels.ImageData, expected: pixels.ImageData }
export type Fixture = {
  settings: config.Settings,
  renderer: draw.Renderer,
  analytic: reference.Renderer,
  texture: Texture,
  stereoTexture: Texture,
  pass: Pass,
  view: number,
}
export type Metrics = { maximum: number, mean: number, rms: number, alpha: number, alphaMean: number }
local WIDTH, HEIGHT = 96, 64
local DIAGNOSTICS: { selection.Diagnostic } = { 'none', 'direction', 'coordinates', 'cells', 'density', 'field' }
local ANGLES = {
  front = vector.pack(0, 0.4, -1),
  seam = vector.pack(0, 0.4, 1),
  side = vector.pack(1, 0.4, 0),
  down = vector.pack(0, -1, 0),
  up = vector.pack(0, 1, 0),
}

function capture.withFixture(input: config.Config, run: (Fixture) -> ()): ()
  local releases: { () -> () } = {}
  local function keep<T>(resource: T & { release: (any) -> () }): T
    table.insert(releases, 1, function(): ()
      resource:release()
    end)
    return resource
  end
  local ok, failure = pcall(function(): ()
    local settings = config.schema.parse(input)
    local current = { settings = settings, view = 0 }
    local owner = plugin.consumer {
      name = 'graphics/aurora-curtain-texture',
      init = function(context: plugin.Context): ()
        current.renderer = draw.new(context, settings, function(): selection.Diagnostic
          return DIAGNOSTICS[current.view + 1]
        end)
      end,
    }
    local session = testing.start { { id = 'graphics/aurora-curtain-texture', definition = owner.definition } }
    table.insert(releases, 1, function(): ()
      session:close()
    end)
    testing.expect.equal(session.instances['graphics/aurora-curtain-texture']:state(), 'active', 'real runtime owner')
    current.analytic = reference.new(settings, keep)
    local options = {
      format = 'rgba32f',
      linear = true,
      samples = 1,
      mipmaps = false,
      usage = { 'render', 'transfer' },
    }
    current.texture = keep(lovr.graphics.newTexture(WIDTH, HEIGHT, options))
    current.stereoTexture = keep(lovr.graphics.newTexture(WIDTH, HEIGHT, 2, options))
    current.pass = keep(lovr.graphics.newPass { texture = current.texture, depth = false, samples = 1 })
    run(current)
  end)
  local closed, closeFailure = pcall(cleanup.run, 'aurora curtain texture oracle', releases)
  if not ok then
    error(tostring(failure) .. (if closed then '' else '\n' .. tostring(closeFailure)), 0)
  end
  assert(closed, closeFailure)
end

function capture.observed(scenario: Scenario): model.Frame
  local waves: { model.Wave } = {}
  local bands: { model.Band } = { 'treble', 'bass', 'mid', 'treble', 'mid', 'bass', 'mid' }
  local counts = { bass = 0, mid = 0, treble = 0 }
  local ages = { 0, 0.079, 0.081, 0.3, 0.7 }
  local index = 0
  local count = scenario.count or 0
  assert(count <= (if scenario.band then model.wavePools[scenario.band] else model.MAX_WAVES), 'valid pool count')
  while #waves < count do
    index += 1
    local band = scenario.band or bands[(index - 1) % #bands + 1]
    if counts[band] >= model.wavePools[band] then
      continue
    end
    counts[band] += 1
    local fraction = (#waves + 1) / model.MAX_WAVES
    table.insert(waves, {
      age = scenario.age or ages[(index - 1) % #ages + 1],
      strength = (scenario.strength or 1) * (0.98 - fraction * 0.5),
      position = (
        (if scenario.seam then (if #waves % 2 == 0 then 0.998 else 0.002) else 0.98 + fraction * 0.91)
        + (scenario.shift or 0)
      ) % 1,
      band = band,
      lifetime = model.waveLifetimes[band],
      frequency = fraction,
    })
  end
  if scenario.reverse then
    local reversed: { model.Wave } = {}
    for i = #waves, 1, -1 do
      table.insert(reversed, waves[i])
    end
    waves = reversed
  end
  local spectrum, stereo = {}, {}
  for band, amount in { 0.8, 0.35, 0.6, 0.9, 0.25, 0.7, 0.45, 1 } do
    spectrum[band] = amount
    stereo[band] = amount * (if band % 2 == 0 then 0.7 else -0.6)
  end
  -- Repeated clocks deliberately receive fresh identities, just as two distinct model updates do.
  return {
    visibility = scenario.visibility or 1,
    time = scenario.time or 123,
    bass = 0.8,
    mid = 0.7,
    treble = 0.9,
    brightness = if scenario.brightness == nil then 1 else scenario.brightness,
    spectrum = spectrum,
    stereo = stereo,
    responseStrength = 1,
    discardedHops = 0,
    waves = waves,
  }
end

function capture.images(
  current: Fixture,
  scenario: Scenario,
  frame: model.Frame,
  production: boolean
): { pixels.ImageData }
  local pass = current.pass
  local texture = if scenario.stereo then current.stereoTexture else current.texture
  pass:reset()
  pass:setCanvas { texture = texture, depth = false, samples = 1 }
  pass:setClear(0, 0, 0, 0)
  pass:setProjection('perspective', math.rad(80), WIDTH / HEIGHT, 0.1, 0)
  pass:setDepthTest()
  pass:setDepthWrite(false)
  pass:setCullMode(nil)
  pass:origin()
  local views = if scenario.stereo then 2 else 1
  assert(pass:getViewCount() == views, 'array canvas supplies the requested view count')
  for view = 1, views do
    local offset = if scenario.stereo then (if view == 1 then -0.032 else 0.032) else 0
    local eye = if scenario.miniature or scenario.shared
      then vector.pack(offset, -1.8, 2.4)
      else vector.pack(offset, 0, 0)
    local direction = if scenario.miniature or scenario.shared then -eye else ANGLES[scenario.angle or 'front']
    local up = if scenario.angle == 'down' or scenario.angle == 'up' then vector.pack(0, 0, 1) else vector.pack(0, 1, 0)
    pass:setViewPose(view, lovr.math.mat4():target(eye, direction, up))
  end
  local facing = scenario.facing or 0.5
  local function miniature(radius: number, opacity: number): ()
    if production then
      current.renderer.miniature(pass, frame, radius, facing, opacity)
    else
      pass:push()
      pass:scale(radius / current.settings.distance)
      current.analytic.render(pass, frame, opacity, 0, facing, true)
      pass:pop()
    end
  end
  if scenario.miniature then
    miniature(1, 0.7)
  else
    if production then
      current.renderer.render(pass, frame, vector.zero, facing)
    else
      current.analytic.render(pass, frame, frame.visibility, scenario.view or 0, facing)
    end
    if scenario.shared then
      -- Both eyes, the scene, and the visible miniature use exactly one Frame in one submitted pass.
      pass:origin()
      miniature(0.8, 0.65)
    end
  end
  assert(lovr.graphics.submit(pass), 'curtain capture submission succeeds')
  local readbacks = {}
  for layer = 1, views do
    -- Lua's one-based layers 1 and 2 read GPU layers 0 and 1 independently.
    readbacks[layer] = texture:newReadback(0, 0, layer)
  end
  assert(lovr.graphics.submit {}, 'curtain readback submission succeeds')
  local images = {}
  for layer, readback in readbacks do
    readback:wait()
    assert(readback:isComplete(), 'layered readback completes')
    local image = readback:getImage()
    assert(image, 'layered readback returns an image')
    local ok, result = pcall(pixels.read, image)
    image:release()
    readback:release()
    assert(ok, result)
    images[layer] = result
  end
  return images
end

function capture.metrics(actual: pixels.ImageData, expected: pixels.ImageData): Metrics
  assert(actual.width == expected.width and actual.height == expected.height, 'image dimensions agree')
  local maximum, sum, square, alpha, alphaSum = 0, 0, 0, 0, 0
  for index, p in actual.values do
    local q = expected.values[index]
    for _, value in { p.r, p.g, p.b, p.a, q.r, q.g, q.b, q.a } do
      assert(value == value and math.abs(value) < math.huge, 'all rendered channels are finite')
    end
    for channel = 1, 3 do
      local a = if channel == 1 then p.r elseif channel == 2 then p.g else p.b
      local b = if channel == 1 then q.r elseif channel == 2 then q.g else q.b
      local error = math.abs(a - b)
      maximum = math.max(maximum, error)
      sum += error
      square += error * error
    end
    local difference = math.abs(p.a - q.a)
    alpha = math.max(alpha, difference)
    alphaSum += difference
  end
  local count = #actual.values * 3
  return {
    maximum = maximum,
    mean = sum / count,
    rms = math.sqrt(square / count),
    alpha = alpha,
    alphaMean = alphaSum / #actual.values,
  }
end

function capture.tracksChange(previous: Pair, current: Pair, label: string): ()
  local referenceSquare, residualSquare, dot = 0, 0, 0
  for index, p in current.expected.values do
    local oldReference = previous.expected.values[index]
    local actual, oldActual = current.actual.values[index], previous.actual.values[index]
    for _, channel in { 'r', 'g', 'b' } do
      local expectedDelta = p[channel] - oldReference[channel]
      local actualDelta = actual[channel] - oldActual[channel]
      referenceSquare += expectedDelta * expectedDelta
      residualSquare += (actualDelta - expectedDelta) ^ 2
      dot += expectedDelta * actualDelta
    end
  end
  local magnitude = math.sqrt(referenceSquare / (#current.expected.values * 3))
  local relative = math.sqrt(residualSquare / math.max(referenceSquare, 1e-30))
  local projection = dot / math.max(referenceSquare, 1e-30)
  local detail = string.format(
    '%s: reference delta RMS %.9g relative residual %.6f projection %.6f',
    label,
    magnitude,
    relative,
    projection
  )
  print('aurora curtain update ' .. detail)
  assert(magnitude > 1e-7, 'reference demonstrably changes; ' .. detail)
  -- A stale field has a relative residual near one and no projection onto the reference's change.
  assert(relative < 0.75 and projection > 0.25, 'production follows the independent reference change; ' .. detail)
end

return capture
