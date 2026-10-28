-- Compares the real scene and miniature renderer against an independent frozen analytic composite.
local testing = require '@testing'
local plugin = require '@lunette-plugin'
local config = require '@lunette-plugins/environment/backdrop/config'
local draw = require '@lunette-plugins/environment/backdrop/private/rendering/draw'
local model = require '@lunette-plugins/environment/backdrop/private/rendering/model'
local selection = require '@lunette-plugins/environment/backdrop/private/selection/selection'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local reference = require './support/aurora-analytic-scene'
local pixels = require './support/pixels'
local render = require './support/render'

local test = testing.suite()
local WIDTH, HEIGHT = 96, 64
-- The 384-square half-float field is an approximation, not an exact shader rewrite. These linear RGB budgets
-- bound isolated sharp-ray errors as well as whole-image error; alpha and analytic-only branches stay separate.
local MAX_ERROR, MEAN_ERROR, RMS_ERROR = 0.06, 0.0004, 0.002
local ANALYTIC_ERROR, ALPHA_ERROR = 1e-4, 1e-6
local DIAGNOSTICS: { selection.Diagnostic } = { 'none', 'direction', 'coordinates', 'cells', 'density', 'field' }
local ANGLES = {
  horizon = { vector.pack(0, 0, -1), vector.pack(0, 1, 0) },
  up = { vector.pack(0, 1, 0), vector.pack(0, 0, 1) },
  down = { vector.pack(0, -1, 0), vector.pack(0, 0, 1) },
  side = { vector.pack(1, 0, 0), vector.pack(0, 1, 0) },
}

type Scenario = {
  name: string,
  time: number?,
  energy: number?,
  count: number?,
  brightness: number?,
  visibility: number?,
  angle: string?,
  view: number?,
  miniature: boolean?,
  shared: boolean?,
  exact: boolean?,
}
type Pair = { actual: pixels.ImageData, expected: pixels.ImageData }
type Metrics = { maximum: number, mean: number, rms: number, alpha: number }
type Fixture = {
  settings: config.Settings,
  renderer: draw.Renderer,
  analytic: reference.Renderer,
  texture: Texture,
  pass: Pass,
  view: number,
}

local function withFixture(run: (Fixture) -> ()): ()
  local releases: { () -> () } = {}
  local function keep<T>(resource: T & { release: (any) -> () }): T
    table.insert(releases, 1, function(): ()
      resource:release()
    end)
    return resource
  end
  local ok, failure = pcall(function(): ()
    local settings = config.schema.parse {}
    local current = { settings = settings, view = 0 }
    local owner = plugin.consumer {
      name = 'graphics/aurora-sky-texture',
      init = function(context: plugin.Context): ()
        current.renderer = draw.new(context, settings, function(): selection.Diagnostic
          return DIAGNOSTICS[current.view + 1]
        end)
      end,
    }
    local session = testing.start { { id = 'graphics/aurora-sky-texture', definition = owner.definition } }
    table.insert(releases, 1, function(): ()
      session:close()
    end)
    testing.expect.equal(session.instances['graphics/aurora-sky-texture']:state(), 'active', 'real runtime owner')
    current.analytic = reference.new(settings, keep)
    current.texture = keep(lovr.graphics.newTexture(WIDTH, HEIGHT, {
      format = 'rgba32f',
      linear = true,
      samples = 1,
      mipmaps = false,
      usage = { 'render', 'transfer' },
    }))
    current.pass = keep(lovr.graphics.newPass { texture = current.texture, depth = false, samples = 1 })
    run(current)
  end)
  local closed, closeFailure = pcall(cleanup.run, 'aurora sky texture oracle', releases)
  if not ok then
    error(tostring(failure) .. (if closed then '' else '\n' .. tostring(closeFailure)), 0)
  end
  assert(closed, closeFailure)
end

local function observed(scenario: Scenario): model.Frame
  local energy = scenario.energy or 0
  local waves: { model.Wave } = {}
  local bands: { model.Band } = { 'treble', 'bass', 'mid', 'treble', 'mid', 'bass', 'mid' }
  local counts = { bass = 0, mid = 0, treble = 0 }
  local ages = { 0, 0.02, 0.079, 0.08, 0.081, 0.3, 0.7 }
  local index = 0
  while #waves < (scenario.count or 0) do
    index += 1
    local band = bands[(index - 1) % #bands + 1]
    if counts[band] >= model.wavePools[band] then
      continue
    end
    counts[band] += 1
    local fraction = (#waves + 1) / model.MAX_WAVES
    table.insert(waves, {
      age = ages[(index - 1) % #ages + 1],
      strength = 0.95 - fraction * 0.6,
      position = (0.98 + fraction * 0.91) % 1,
      band = band,
      lifetime = model.waveLifetimes[band],
      frequency = fraction,
    })
  end
  local spectrum, stereo = {}, {}
  for band, amount in { 0.8, 0.35, 0.6, 0.9, 0.25, 0.7, 0.45, 1 } do
    spectrum[band] = amount * energy
    stereo[band] = amount * energy * (if band % 2 == 0 then 0.7 else -0.6)
  end
  -- Every call returns a new frame, including repeated clocks: the renderer caches by frame identity.
  return {
    visibility = scenario.visibility or 1,
    time = scenario.time or 0,
    bass = energy,
    mid = energy,
    treble = energy,
    brightness = if scenario.brightness == nil then 1 else scenario.brightness,
    spectrum = spectrum,
    stereo = stereo,
    responseStrength = energy,
    discardedHops = 0,
    waves = waves,
  }
end

local function capture(current: Fixture, scenario: Scenario, frame: model.Frame, production: boolean): pixels.ImageData
  local pass = current.pass
  pass:reset()
  pass:setCanvas { texture = current.texture, depth = false, samples = 1 }
  pass:setClear(0, 0, 0, 0)
  pass:setProjection('perspective', math.rad(80), WIDTH / HEIGHT, 0.1, 0)
  pass:setDepthTest()
  pass:setDepthWrite(false)
  pass:setCullMode(nil)
  pass:origin()
  if scenario.miniature then
    local eye = vector.pack(0, -1.8, 2.4)
    pass:setViewPose(1, lovr.math.mat4():target(eye, -eye, vector.pack(0, 1, 0)))
    if production then
      current.renderer.miniature(pass, frame, 1, 0.5, 0.7)
    else
      pass:scale(1 / current.settings.distance)
      current.analytic.render(pass, frame, 0.7, 0, true)
    end
  else
    local angle = ANGLES[scenario.angle or 'up']
    pass:setViewPose(1, lovr.math.mat4():target(vector.zero, angle[1], angle[2]))
    if production then
      current.renderer.render(pass, frame, vector.zero, 0.5)
    else
      current.analytic.render(pass, frame, frame.visibility, scenario.view or 0)
    end
    if scenario.shared then
      -- A diagnostic scene and normal miniature share one frame and one pass, as in the controls panel.
      pass:origin()
      pass:translate(0, 2.2, 0)
      if production then
        current.renderer.miniature(pass, frame, 0.7, 0.5, 0.8)
      else
        pass:scale(0.7 / current.settings.distance)
        current.analytic.render(pass, frame, 0.8, 0, true)
      end
    end
  end
  -- Submit and read before another frame can write the renderer's shared field texture.
  local image = render.read(current.texture, pass)
  local ok, result = pcall(pixels.read, image)
  image:release()
  assert(ok, result)
  return result
end

local function metrics(actual: pixels.ImageData, expected: pixels.ImageData): Metrics
  assert(actual.width == expected.width and actual.height == expected.height, 'image dimensions agree')
  local maximum, sum, square, alpha = 0, 0, 0, 0
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
    alpha = math.max(alpha, math.abs(p.a - q.a))
  end
  local count = #actual.values * 3
  return { maximum = maximum, mean = sum / count, rms = math.sqrt(square / count), alpha = alpha }
end

local function compare(current: Fixture, scenario: Scenario): Pair
  current.view = scenario.view or 0
  local frame = observed(scenario)
  local actual = capture(current, scenario, frame, true)
  local expected = capture(current, scenario, frame, false)
  local error = metrics(actual, expected)
  local detail = string.format(
    '%s: max %.9g mean %.9g rms %.9g alpha %.9g',
    scenario.name,
    error.maximum,
    error.mean,
    error.rms,
    error.alpha
  )
  print('aurora sky texture ' .. detail)
  assert(error.alpha <= ALPHA_ERROR, 'alpha remains analytic; ' .. detail)
  if scenario.exact then
    assert(error.maximum <= ANALYTIC_ERROR, 'analytic-only branch; ' .. detail)
  else
    assert(error.maximum <= MAX_ERROR and error.mean <= MEAN_ERROR and error.rms <= RMS_ERROR, detail)
  end
  local summary = pixels.summary(actual)
  assert(
    summary.alpha > (if scenario.miniature then 0.01 else 0.99 * frame.visibility),
    'nonempty coverage; ' .. detail
  )
  if frame.brightness > 0 or current.view > 0 then
    assert(summary.high > 0.001, 'nonblank rendered RGB; ' .. detail)
  end
  return { actual = actual, expected = expected }
end

local function tracksChange(previous: Pair, current: Pair, label: string): ()
  local referenceSquare, residualSquare, dot = 0, 0, 0
  for index, p in current.expected.values do
    local oldReference = previous.expected.values[index]
    local actual, oldActual = current.actual.values[index], previous.actual.values[index]
    for channel = 1, 3 do
      local function component(sample: pixels.Sample): number
        return if channel == 1 then sample.r elseif channel == 2 then sample.g else sample.b
      end
      local expectedDelta = component(p) - component(oldReference)
      local actualDelta = component(actual) - component(oldActual)
      referenceSquare += expectedDelta * expectedDelta
      residualSquare += (actualDelta - expectedDelta) ^ 2
      dot += expectedDelta * actualDelta
    end
  end
  local magnitude = math.sqrt(referenceSquare / (#current.expected.values * 3))
  local relative = math.sqrt(residualSquare / math.max(referenceSquare, 1e-30))
  local projection = dot / math.max(referenceSquare, 1e-30)
  local detail = string.format(
    '%s: reference delta RMS %.9g, relative residual %.6f, projection %.6f',
    label,
    magnitude,
    relative,
    projection
  )
  print('aurora sky texture update ' .. detail)
  assert(magnitude > 1e-7, 'reference demonstrably changes; ' .. detail)
  -- A stale field has a relative residual near one and no projection onto the reference's change.
  assert(relative < 0.75 and projection > 0.25, 'the production field tracks the reference change; ' .. detail)
end

test(
  'the production sky texture preserves the frozen analytic scene and miniature within a linear visual budget',
  function(): ()
    withFixture(function(current: Fixture): ()
      for _, time in { 0, 123, 4095 } do
        for _, angle in { 'horizon', 'up', 'down', 'side' } do
          for _, energy in { 0, 1 } do
            compare(current, {
              name = string.format('scene %s t=%g energy=%g', angle, time, energy),
              time = time,
              angle = angle,
              energy = energy,
              count = if energy == 0 then 0 else model.MAX_WAVES,
              exact = angle == 'down',
            })
          end
        end
        compare(current, { name = 'miniature t=' .. time, time = time, energy = 1, count = 7, miniature = true })
      end
      compare(current, { name = 'faded scene', time = 123, visibility = 0.35, energy = 1, count = 3 })
      compare(current, { name = 'zero brightness', time = 123, brightness = 0, energy = 1, count = 7, exact = true })
      for view = 1, 5 do
        compare(
          current,
          { name = 'diagnostic ' .. DIAGNOSTICS[view + 1], time = 123, energy = 1, view = view, exact = true }
        )
      end
      compare(
        current,
        { name = 'diagnostic scene plus normal miniature', time = 123, energy = 1, count = 7, view = 4, shared = true }
      )
    end)
  end
)

test('the production sky texture refreshes at 90 Hz across clock wrap and same-clock energy changes', function(): ()
  withFixture(function(current: Fixture): ()
    for _, clocks in
      {
        { 123 - 1 / 90, 123, 123 + 1 / 90 },
        { 4096 - 2 / 90, 4096 - 1 / 90, 0, 1 / 90 },
      }
    do
      local previous: Pair? = nil
      for _, time in clocks do
        local label = string.format('90 Hz t=%.9f', time)
        local pair = compare(current, { name = label, time = time, energy = 1 })
        if previous then
          tracksChange(previous, pair, label)
        end
        previous = pair
      end
    end
    local quiet = compare(current, { name = 'same clock quiet', time = 123, energy = 0 })
    local loud = compare(current, { name = 'same clock loud', time = 123, energy = 1 })
    tracksChange(quiet, loud, 'same clock energy update')
    local quietAgain = compare(current, { name = 'same clock quiet again', time = 123, energy = 0 })
    tracksChange(loud, quietAgain, 'same clock energy recovery')
  end)
end)

return test
