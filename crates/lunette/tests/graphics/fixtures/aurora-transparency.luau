-- Pixel checks for production fades, foreground silhouettes, and restored draw state.

local testing = require '@testing'
local aurora = require './support/aurora'
local pixels = require './support/pixels'
local render = require './support/render'
local drawing = require '@lunette-plugins/graphics/rounded-drawing'
local geometry = require '@lunette-plugins/graphics/rounded-geometry'
local test = testing.suite()
local expect = testing.expect

local function closeColor(actual: pixels.Sample, wanted: pixels.Sample, label: string): ()
  for _, channel in { 'r', 'g', 'b', 'a' } do
    expect.near(actual[channel], wanted[channel], 2 / 255, label .. ' ' .. channel)
  end
end

local function face(pass: Pass, cache: drawing.Cache, distance: number, size: number, radius: number): ()
  pass:push 'transform'
  pass:translate(0, 0, -distance)
  drawing.face(pass, cache, { x = -size / 2, y = -size / 2, width = size, height = size }, geometry.uniform(radius))
  pass:pop 'transform'
end

local function foreground(current: aurora.Fixture, cache: drawing.Cache, rounded: boolean): pixels.ImageData
  local pass = aurora.prepare(current)
  pass:setShader 'unlit'
  aurora.draw(current, pass)
  pass:setColor(1, 0, 0, 1)
  face(pass, cache, 2, 1.2, if rounded then 0.35 else 0)
  pass:setColor(0, 0, 1, 1)
  face(pass, cache, 3, 1.8, 0)
  return pixels.read(render.read(current.texture, pass))
end

test('aurora_transparency_and_occlusion_pixels', function(): ()
  aurora.withFixture({ motion = 0, response = 1 }, function(current: aurora.Fixture): ()
    for _, p in pixels.read(aurora.capture(current)).values do
      expect.equal(p.a, 0, 'initial hidden alpha')
      expect.equal(p.r + p.g + p.b, 0, 'initial hidden RGB')
    end
    local previous = 0
    for _, visibility in { 0.25, 0.5, 0.75 } do
      aurora.update(current, 0.2, false)
      expect.near(current.state.visibility, visibility, 1e-7, 'production fade visibility')
      local image = pixels.read(aurora.capture(current))
      local summary = pixels.summary(image)
      expect.truthy(summary.alpha > previous and summary.alpha < 1, 'partial fade has continuous alpha')
      for _, p in image.values do
        expect.truthy(p.a >= visibility - 1 / 255 and p.a < 0.99, 'partial sky and curtain alpha')
        expect.truthy(math.max(p.r, p.g, p.b) <= p.a + 1 / 255, 'premultiplied output bounds')
      end
      previous = summary.alpha
    end
    aurora.update(current, 0.2, true)
    expect.near(current.state.visibility, 0.5, 1e-7, 'main session reverses from current fade')
    local reversed = pixels.summary(pixels.read(aurora.capture(current)))
    expect.truthy(reversed.alpha < previous and reversed.alpha > 0, 'main-session fade changes pixels continuously')
    aurora.update(current, 0.1, false)
    expect.near(current.state.visibility, 0.625, 1e-7, 'main session false resumes the current fade')
    current.factory.controls.setEnabled(false)
    aurora.update(current, 1, false)
    for _, p in pixels.read(aurora.capture(current)).values do
      expect.equal(p.a, 0, 'disabled hidden alpha')
    end
    current.factory.controls.setEnabled(true)
    aurora.settle(current)
    local cache = drawing.newCache()
    local ok, failure = pcall(function(): ()
      local opaque = foreground(current, cache, false)
      closeColor(
        pixels.at(opaque, 96, 64),
        { r = 1, g = 0, b = 0, a = 1 },
        'opaque foreground and normal near/far depth'
      )
      local rounded = foreground(current, cache, true)
      closeColor(pixels.at(rounded, 96, 64), pixels.at(opaque, 96, 64), 'rounded interior writes depth')
      closeColor(pixels.at(rounded, 74, 86), { r = 0, g = 0, b = 1, a = 1 }, 'rounded cutout has no foreground depth')
      local pass = aurora.prepare(current)
      local before = { pass:getViewPose(1) }
      aurora.draw(current, pass)
      local after = { pass:getViewPose(1) }
      for index, value in before do
        expect.near(after[index], value, 1e-8, 'view pose remains unchanged')
      end
      -- No renderer-state resets before the white draw; color, shader, material,
      -- blend, and transform must match the defaults, with normal depth writes.
      face(pass, cache, 2, 0.7, 0)
      pass:setColor(1, 0, 0, 1)
      face(pass, cache, 3, 1.2, 0)
      local followup = pixels.read(render.read(current.texture, pass))
      closeColor(
        pixels.at(followup, 96, 64),
        { r = 1, g = 1, b = 1, a = 1 },
        'follow-up draw restores default state and depth'
      )
      local base = pixels.read(aurora.capture(current))
      pass = aurora.prepare(current)
      pass:setShader 'unlit'
      aurora.draw(current, pass)
      pass:setDepthWrite(false)
      pass:setColor(1, 0, 0, 0.5)
      face(pass, cache, 2, 1.2, 0)
      local translucent = pixels.read(render.read(current.texture, pass))
      local p, b = pixels.at(translucent, 96, 64), pixels.at(base, 96, 64)
      closeColor(
        p,
        { r = 0.5 + b.r * 0.5, g = b.g * 0.5, b = b.b * 0.5, a = 1 },
        'translucent foreground retains aurora behind it'
      )
      expect.truthy(p.g > 0, 'background contributes through partial foreground alpha')
    end)
    drawing.clear(cache)
    assert(ok, failure)
  end)
end)

return test
