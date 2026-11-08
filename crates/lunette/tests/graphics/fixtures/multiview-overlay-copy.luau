-- Raster coverage complements the native OpenVR backend recorder; this fixture does not execute OpenVR.
local testing = require '@testing'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local passState = require '@lunette-plugins/graphics/pass-state'
local overlay = require './support/overlay-copy'

local test = testing.suite()
local WIDTH, HEIGHT = 192, 128
local VERTEX = [[
  vec4 lovrmain() {
    return DefaultPosition;
  }
]]
local PATTERN = [[
  vec4 panel(float eye) {
    vec3 gradient = vec3(.12 + UV.x * .4, .08 + UV.y * .3, .15 + UV.x * UV.y * .2);
    vec3 marker = eye < .5 ? vec3(.85, .08, .18) : vec3(.06, .72, .9);
    vec3 color = UV.x < .32 || (UV.y > .6 && UV.x > .65) ? marker : gradient;
    return vec4(color, .45 + UV.y * .4);
  }
]]
type Difference = { maximum: number, mean: number, rms: number, alpha: number, coverage: number, edge: number }
local capture: (number, overlay.Keep) -> ()
local target: (number, boolean, overlay.Keep) -> (Texture, Pass)
local camera: (Pass, number, number) -> ()
local scene: (Pass, Shader, number?) -> ()
local difference: (Image, Image) -> Difference

for _, samples in { 1, 4 } do
  test('resolved multiview overlay copies preserve shader eye index and camera with samples=' .. samples, function(): ()
    local releases: { () -> () } = {}
    local function keep<T>(resource: T & { release: (any) -> () }): T
      table.insert(releases, 1, function(): ()
        resource:release()
      end)
      return resource
    end
    local ok, failure = pcall(capture, samples, keep)
    local closed, closeFailure = pcall(cleanup.run, 'multiview overlay copy', releases)
    if not ok then
      error(tostring(failure) .. (if closed then '' else '\n' .. tostring(closeFailure)), 0)
    end
    assert(closed, closeFailure)
  end)
end

capture = function(samples: number, keep: overlay.Keep): ()
  local multiview = keep(lovr.graphics.newShader(VERTEX, PATTERN .. [[
    vec4 lovrmain() { return panel(float(ViewIndex)); }
  ]]))
  -- Single-view references never read ViewIndex, including the expected right eye.
  local direct = keep(lovr.graphics.newShader(VERTEX, PATTERN .. [[
    uniform int referenceEye;
    vec4 lovrmain() { return panel(float(referenceEye)); }
  ]]))
  local array, pass = target(samples, true, keep)
  for eye = 1, 2 do
    camera(pass, eye, eye)
  end
  scene(pass, multiview)
  local expected, wrongCamera = {}, {}
  local passes = { pass }
  for eye = 1, 2 do
    local texture, referencePass = target(samples, false, keep)
    camera(referencePass, 1, eye)
    scene(referencePass, direct, eye - 1)
    expected[eye] = texture
    table.insert(passes, referencePass)
    local wrongTexture, wrongPass = target(samples, false, keep)
    camera(wrongPass, 1, 3 - eye)
    scene(wrongPass, direct, eye - 1)
    wrongCamera[eye] = wrongTexture
    table.insert(passes, wrongPass)
  end
  assert(lovr.graphics.submit(passes), 'multiview and independent single-view submissions succeed')
  local outputs = overlay.layers(array, keep)
  local pending = {}
  for eye = 1, 2 do
    pending[eye] = {
      keep(outputs[eye]:newReadback()),
      keep(array:newReadback(0, 0, eye)),
      keep(expected[eye]:newReadback()),
      keep(wrongCamera[eye]:newReadback()),
    }
  end
  assert(lovr.graphics.submit {}, 'overlay copies and readbacks flush after the resolved render')
  local images = {}
  for eye, readbacks in pending do
    images[eye] = {}
    for index, readback in readbacks do
      images[eye][index] = overlay.image(readback, keep)
    end
  end
  for eye = 1, 2 do
    local image, source, reference, wrong = unpack(images[eye])
    local label = string.format('eye=%d samples=%d', eye - 1, samples)
    overlay.identical(image, source, label .. ' copied array layer')
    local matching = difference(image, reference)
    local opposite = difference(image, images[3 - eye][3])
    local cameraOnly = difference(image, wrong)
    local detail = string.format(
      '%s: RGB max %.9g mean %.9g RMS %.9g alpha %.9g opposite RMS %.9g wrong-camera RMS %.9g',
      label,
      matching.maximum,
      matching.mean,
      matching.rms,
      matching.alpha,
      opposite.rms,
      cameraOnly.rms
    )
    print('multiview overlay copy ' .. detail)
    assert(matching.coverage > 0.04 and matching.coverage < 0.8, 'world-space panels have partial coverage; ' .. detail)
    assert(
      matching.maximum <= 1 / 255 + 1e-7 and matching.mean <= 1e-5 and matching.rms <= 1e-4,
      'full-image overlay matches the independent single-view eye; ' .. detail
    )
    assert(matching.alpha <= 1 / 255 + 1e-7, 'full-image overlay alpha matches the direct eye; ' .. detail)
    assert(opposite.rms > 0.02, 'the deliberately opposite expected eye cannot pass a tight match; ' .. detail)
    assert(cameraOnly.rms > 0.02, 'correct eye colours with the opposite camera cannot pass a tight match; ' .. detail)
    if samples == 4 then
      assert(matching.edge > 0, 'the copied image contains partially covered MSAA edge pixels; ' .. detail)
    end
  end
end

target = function(samples: number, stereo: boolean, keep: overlay.Keep): (Texture, Pass)
  local options = {
    type = if stereo then 'array' else '2d',
    format = 'rgba8',
    linear = true,
    samples = 1,
    mipmaps = false,
    usage = { 'render', 'transfer' },
  }
  local texture = keep(
    if stereo
      then lovr.graphics.newTexture(WIDTH, HEIGHT, 2, options)
      else lovr.graphics.newTexture(WIDTH, HEIGHT, options)
  )
  local pass = keep(lovr.graphics.newPass { texture = texture, depth = false, samples = samples })
  pass:setClear(0, 0, 0, 0)
  pass:setBlendMode()
  pass:setDepthTest()
  pass:setDepthWrite(false)
  pass:setCullMode()
  pass:setShader 'unlit'
  pass:setColor(0.1, 0.8, 0.2, 0.7)
  assert(pass:getViewCount() == (if stereo then 2 else 1), 'the render pass has the requested view count')
  assert(pass:getCanvas().samples == samples, 'the render pass uses the requested MSAA count')
  return texture, pass
end

camera = function(pass: Pass, view: number, eye: number): ()
  local position = if eye == 1 then vector.pack(-0.18, 0.07, 0.15) else vector.pack(0.22, -0.04, 0.05)
  local direction = if eye == 1 then vector.pack(-0.05, 0.03, -1) else vector.pack(0.04, -0.02, -1)
  pass:setViewPose(view, lovr.math.mat4():target(position, position + direction, vector.pack(0, 1, 0)), false)
  pass:setProjection(
    view,
    'asymmetric',
    if eye == 1 then 0.7 else 0.83,
    if eye == 1 then 0.85 else 0.68,
    0.7,
    0.74,
    0.1,
    0
  )
end

scene = function(pass: Pass, shader: Shader, eye: number?): ()
  passState.withRestore(pass, function(): ()
    pass:setShader(shader)
    pass:setColor(1, 1, 1, 1)
    pass:origin()
    if eye ~= nil then
      pass:send('referenceEye', eye)
    end
    pass:plane(-0.3, 0.08, -1.9, 1.3, 1.05, 0.2, 0, 1, 0)
    pass:plane(0.65, -0.36, -2.8, 0.7, 0.8, 0.27, 0, 0, 1)
  end)
  -- The follow-up draw uses the restored shader, colour, and transform in every view.
  pass:plane(-0.75, -0.55, -1.5, 0.25, 0.2)
end

difference = function(actual: Image, expected: Image): Difference
  assert(actual:getWidth() == WIDTH and actual:getHeight() == HEIGHT, 'actual image dimensions')
  assert(expected:getWidth() == WIDTH and expected:getHeight() == HEIGHT, 'expected image dimensions')
  local maximum, sum, square, alpha, covered, edge = 0, 0, 0, 0, 0, 0
  for y = 0, HEIGHT - 1 do
    for x = 0, WIDTH - 1 do
      local ar, ag, ab, aa = actual:getPixel(x, y)
      local er, eg, eb, ea = expected:getPixel(x, y)
      local dr, dg, db = math.abs(ar - er), math.abs(ag - eg), math.abs(ab - eb)
      maximum = math.max(maximum, dr, dg, db)
      sum += dr + dg + db
      square += dr * dr + dg * dg + db * db
      alpha = math.max(alpha, math.abs(aa - ea))
      covered += if ar + ag + ab > 2 / 255 then 1 else 0
      edge += if aa > 0 and aa < 0.4 then 1 else 0
    end
  end
  local count = WIDTH * HEIGHT
  return {
    maximum = maximum,
    mean = sum / (count * 3),
    rms = math.sqrt(square / (count * 3)),
    alpha = alpha,
    coverage = covered / count,
    edge = edge,
  }
end

return test
