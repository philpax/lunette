-- Captures the actual plugin-owned renderer and an independent direct composition on eligible stereo canvases.
local testing = require '@testing'
local plugin = require '@lunette-plugin'
local config = require '@lunette-plugins/environment/backdrop/config'
local draw = require '@lunette-plugins/environment/backdrop/private/rendering/draw'
local model = require '@lunette-plugins/environment/backdrop/private/rendering/model'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local frames = require './aurora-curtain-capture'
local reference = require './aurora-direct-scene'
local overlay = require './overlay-copy'

local capture = {}
export type Scenario = {
  name: string,
  angle: ('horizon' | 'up' | 'down')?,
  count: number?,
  age: number?,
  shift: number?,
  strength: number?,
  time: number?,
  visibility: number?,
  brightness: number?,
  silent: boolean?,
  samples: number?,
  width: number?,
  height: number?,
  miniature: ('first' | 'last')?,
  overlayCopy: boolean?,
}
export type Bounds = { maximum: number, mean: number, rms: number, alpha: number }
export type Pair = { actual: { number }, expected: { number } }
export type Fixture = {
  settings: config.Settings,
  renderer: draw.Renderer,
  direct: reference.Renderer,
  keep: reference.Keep,
  targets: { [string]: { texture: Texture, pass: Pass } },
  failures: { string },
}
local HEAD = vector.pack(1.25, 1.65, -0.7)
local FACING = 0.73

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
    local current = { settings = settings, keep = keep, targets = {}, failures = {} } :: Fixture
    local owner = plugin.consumer {
      name = 'graphics/aurora-half-resolution',
      init = function(context: plugin.Context): ()
        current.renderer = draw.new(context, settings, function(): 'none'
          return 'none'
        end)
      end,
    }
    local session = testing.start { { id = 'graphics/aurora-half-resolution', definition = owner.definition } }
    table.insert(releases, 1, function(): ()
      session:close()
    end)
    testing.expect.equal(session.instances['graphics/aurora-half-resolution']:state(), 'active', 'real renderer owner')
    current.direct = reference.new(settings, keep)
    run(current)
    assert(#current.failures == 0, table.concat(current.failures, '\n'))
  end)
  local closed, closeFailure = pcall(cleanup.run, 'aurora half-resolution capture', releases)
  if not ok then
    error(tostring(failure) .. (if closed then '' else '\n' .. tostring(closeFailure)), 0)
  end
  assert(closed, closeFailure)
end

function capture.observed(scenario: Scenario): model.Frame
  local frame = frames.observed {
    name = scenario.name,
    count = scenario.count or 34,
    age = scenario.age or 0.081,
    shift = scenario.shift,
    strength = scenario.strength,
    time = scenario.time,
    visibility = scenario.visibility,
    brightness = scenario.brightness,
  }
  if scenario.silent then
    frame.bass, frame.mid, frame.treble, frame.responseStrength = 0, 0, 0, 0
    frame.waves = {}
    for index = 1, 8 do
      frame.spectrum[index], frame.stereo[index] = 0, 0
    end
  end
  return frame
end

local function target(current: Fixture, scenario: Scenario, production: boolean): (Texture, Pass)
  local width, height, samples = scenario.width or 960, scenario.height or 640, scenario.samples or 1
  local key = string.format('%dx%d/%d/%s', width, height, samples, tostring(production))
  if not current.targets[key] then
    local texture = current.keep(lovr.graphics.newTexture(width, height, 2, {
      format = 'rgba8',
      linear = true,
      samples = 1,
      mipmaps = false,
      usage = { 'render', 'transfer' },
    }))
    local pass = current.keep(lovr.graphics.newPass { texture = texture, depth = false, samples = samples })
    current.targets[key] = { texture = texture, pass = pass }
  end
  local held = current.targets[key]
  local pass = held.pass
  pass:reset()
  pass:setCanvas { texture = held.texture, depth = false, samples = samples }
  pass:setClear(0, 0, 0, 0)
  pass:setDepthTest()
  pass:setDepthWrite(false)
  pass:origin()
  assert(pass:getViewCount() == 2 and width >= 960 and height >= 640, 'the actual half-resolution path is eligible')
  assert(pass:getCanvas().samples == samples, 'main canvas uses the requested MSAA count')
  for eye = 1, 2 do
    -- Each eye has an asymmetric frustum and its own translated, rotated camera, not just a shared IPD offset.
    local left, right = if eye == 1 then 0.85 else 0.69, if eye == 1 then 0.68 else 0.87
    pass:setProjection(
      eye,
      'asymmetric',
      left,
      right,
      if eye == 1 then 0.66 else 0.71,
      if eye == 1 then 0.73 else 0.64,
      0.1,
      0
    )
    local position = HEAD + vector.pack(if eye == 1 then -0.034 else 0.031, if eye == 1 then 0.009 else -0.006, 0.018)
    local direction = if scenario.angle == 'up'
      then vector.pack(0.14, 1, -0.08)
      elseif scenario.angle == 'down' then vector.pack(-0.12, -1, -0.09)
      else vector.pack(0.12, 0.32, -1)
    direction += vector.pack(if eye == 1 then -0.018 else 0.025, if eye == 1 then 0.012 else -0.008, 0)
    local up = if scenario.angle == 'up' or scenario.angle == 'down'
      then vector.pack(0, 0, 1)
      else vector.pack(0.035, 1, 0)
    pass:setViewPose(eye, lovr.math.mat4():target(position, position + direction, up))
  end
  return held.texture, pass
end

local function miniature(current: Fixture, pass: Pass, frame: model.Frame, production: boolean): ()
  pass:push()
  pass:origin()
  -- Keep identical miniature work in the main pass but outside both frusta, isolating compute ownership from coverage.
  pass:translate(HEAD + vector.pack(10000, 10000, 10000))
  if production then
    current.renderer.miniature(pass, frame, 0.8, FACING, 0.65)
  else
    pass:scale(0.8 / current.settings.distance)
    current.direct.render(pass, frame, 0.65, FACING, true)
  end
  pass:pop()
end

local function record(
  current: Fixture,
  scenario: Scenario,
  frame: model.Frame,
  production: boolean
): (Texture, { Pass })
  local texture, pass = target(current, scenario, production)
  if scenario.miniature == 'first' then
    miniature(current, pass, frame, production)
  end
  local passes: { Pass } = {}
  if production then
    local preparations = current.renderer.render(pass, frame, HEAD, FACING)
    assert(preparations and #preparations == 1, 'eligible production render returns exactly one preparation pass')
    for _, preparation in preparations do
      local canvas = preparation:getCanvas()
      local width, height = preparation:getDimensions()
      local expected = if (scenario.width or 960) == 1920 and (scenario.height or 640) == 1280
        then { 960, 640 }
        else { 720, 480 }
      assert(width == expected[1] and height == expected[2], 'reduced-resolution preparation dimensions')
      assert(preparation:getViewCount() == 2 and canvas.samples == 1, 'single-sample stereo intermediate')
      assert(canvas[1]:getFormat() == 'rgba16f' and canvas[1]:getSampleCount() == 1, 'HDR intermediate format')
      if scenario.miniature == 'first' and #frame.waves > 8 and frame.brightness > 0 then
        assert(
          preparation:getStats().computes >= 2,
          'preparation owns sky and onset updates despite miniature-first recording'
        )
      end
      table.insert(passes, preparation)
    end
  else
    pass:origin()
    pass:translate(HEAD)
    current.direct.render(pass, frame, frame.visibility, FACING)
  end
  if scenario.miniature == 'last' then
    miniature(current, pass, frame, production)
  end
  table.insert(passes, pass)
  return texture, passes
end

local function measured(
  actual: Image,
  expected: Image,
  snapshotActual: { number },
  snapshotExpected: { number }
): (Bounds, number, number)
  local width, height = actual:getDimensions()
  local ew, eh = expected:getDimensions()
  assert(width == ew and height == eh, 'direct and production image dimensions agree')
  local maximum, sum, square, alpha, nonblankActual, nonblankExpected = 0, 0, 0, 0, 0, 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local ar, ag, ab, aa = actual:getPixel(x, y)
      local er, eg, eb, ea = expected:getPixel(x, y)
      assert(
        ar == ar and ag == ag and ab == ab and aa == aa and er == er and eg == eg and eb == eb and ea == ea,
        'finite channels'
      )
      assert(
        math.max(
          math.abs(ar),
          math.abs(ag),
          math.abs(ab),
          math.abs(aa),
          math.abs(er),
          math.abs(eg),
          math.abs(eb),
          math.abs(ea)
        ) < math.huge,
        'bounded channels'
      )
      local dr, dg, db = math.abs(ar - er), math.abs(ag - eg), math.abs(ab - eb)
      maximum = math.max(maximum, dr, dg, db)
      sum += dr + dg + db
      square += dr * dr + dg * dg + db * db
      alpha = math.max(alpha, math.abs(aa - ea))
      nonblankActual += if ar + ag + ab > 2 / 255 then 1 else 0
      nonblankExpected += if er + eg + eb > 2 / 255 then 1 else 0
      if x % 8 == 4 and y % 8 == 4 then
        table.insert(snapshotActual, ar)
        table.insert(snapshotActual, ag)
        table.insert(snapshotActual, ab)
        table.insert(snapshotExpected, er)
        table.insert(snapshotExpected, eg)
        table.insert(snapshotExpected, eb)
      end
    end
  end
  local count = width * height
  return { maximum = maximum, mean = sum / (count * 3), rms = math.sqrt(square / (count * 3)), alpha = alpha },
    nonblankActual / count,
    nonblankExpected / count
end

function capture.compare(current: Fixture, scenario: Scenario, bounds: Bounds, supplied: model.Frame?): Pair
  local frame = supplied or capture.observed(scenario)
  local actual, passes = record(current, scenario, frame, true)
  local expected, directPasses = record(current, scenario, frame, false)
  for _, pass in directPasses do
    table.insert(passes, pass)
  end
  -- One ordered rendering submission contains preparation, production main, and independent direct main.
  assert(lovr.graphics.submit(passes), 'ordered half-resolution capture submission succeeds')
  local releases: { () -> () } = {}
  local function keep<T>(resource: T & { release: (any) -> () }): T
    table.insert(releases, 1, function(): ()
      resource:release()
    end)
    return resource
  end
  local pair: Pair = { actual = {}, expected = {} }
  local ok, failure = pcall(function(): ()
    local actualEyes = if scenario.overlayCopy then overlay.layers(actual, keep) else nil
    local expectedEyes = if scenario.overlayCopy then overlay.layers(expected, keep) else nil
    local readbacks = {}
    for eye = 1, 2 do
      if actualEyes and expectedEyes then
        readbacks[eye] = {
          keep(actualEyes[eye]:newReadback()),
          keep(expectedEyes[eye]:newReadback()),
          keep(actual:newReadback(0, 0, eye)),
          keep(expected:newReadback(0, 0, eye)),
        }
      else
        readbacks[eye] = { keep(actual:newReadback(0, 0, eye)), keep(expected:newReadback(0, 0, eye)) }
      end
    end
    -- This empty submission flushes fixture transfers and readbacks; production code never submits, waits, or reads pixels.
    assert(lovr.graphics.submit {}, 'layer readback flush succeeds')
    for eye, pending in readbacks do
      local images = {}
      for index, readback in pending do
        images[index] = overlay.image(readback, keep)
      end
      if scenario.overlayCopy then
        overlay.identical(images[1], images[3], scenario.name .. ' production copied eye ' .. eye)
        overlay.identical(images[2], images[4], scenario.name .. ' direct copied eye ' .. eye)
      end
      local error, actualCoverage, expectedCoverage = measured(images[1], images[2], pair.actual, pair.expected)
      local detail = string.format(
        '%s eye=%d samples=%d: RGB max %.9g mean %.9g RMS %.9g alpha max %.9g RGB coverage %.6f/%.6f',
        scenario.name,
        eye - 1,
        scenario.samples or 1,
        error.maximum,
        error.mean,
        error.rms,
        error.alpha,
        actualCoverage,
        expectedCoverage
      )
      print('aurora half-resolution ' .. detail)
      local function check(condition: boolean, reason: string): ()
        if not condition then
          local failure = reason .. '; ' .. detail
          print('aurora half-resolution failure: ' .. failure)
          table.insert(current.failures, failure)
        end
      end
      check(actualCoverage > 0.05 and expectedCoverage > 0.05, 'both images contain RGB independently of alpha')
      check(
        error.maximum <= bounds.maximum and error.mean <= bounds.mean and error.rms <= bounds.rms,
        'half-resolution RGB budget'
      )
      check(error.alpha <= bounds.alpha, 'half-resolution alpha budget')
    end
    local eyeSamples = #pair.actual / 2
    for _, field in { 'actual', 'expected' } do
      local square = 0
      for index = 1, eyeSamples do
        square += (pair[field][index] - pair[field][index + eyeSamples]) ^ 2
      end
      if scenario.angle ~= 'down' then
        assert(math.sqrt(square / eyeSamples) > 1e-5, field .. ' stereo eye RGB differs: ' .. scenario.name)
      end
    end
  end)
  local closed, closeFailure = pcall(cleanup.run, 'aurora half-resolution readbacks', releases)
  if not ok then
    error(tostring(failure) .. (if closed then '' else '\n' .. tostring(closeFailure)), 0)
  end
  assert(closed, closeFailure)
  return pair
end

function capture.identical(a: Pair, b: Pair, label: string): ()
  for _, field in { 'actual', 'expected' } do
    assert(#a[field] == #b[field], 'snapshot dimensions agree')
    for index, value in a[field] do
      assert(math.abs(value - b[field][index]) <= 1e-7, field .. ' repeat is deterministic: ' .. label)
    end
  end
end

function capture.tracksChange(previous: Pair, current: Pair, label: string): ()
  local expectedSquare, actualSquare, dot = 0, 0, 0
  for index, value in current.expected do
    local expectedDelta = value - previous.expected[index]
    local actualDelta = current.actual[index] - previous.actual[index]
    expectedSquare += expectedDelta * expectedDelta
    actualSquare += actualDelta * actualDelta
    dot += expectedDelta * actualDelta
  end
  local expectedRms = math.sqrt(expectedSquare / #current.expected)
  local actualRms = math.sqrt(actualSquare / #current.actual)
  local projection = dot / math.max(expectedSquare, 1e-30)
  local detail = string.format(
    '%s: RGB reference delta RMS %.9g production delta RMS %.9g projection %.6f',
    label,
    expectedRms,
    actualRms,
    projection
  )
  print('aurora half-resolution update ' .. detail)
  assert(
    expectedRms > 1e-6 and actualRms > 1e-6 and projection > 0.25,
    'production follows independent reference motion; ' .. detail
  )
end

return capture
