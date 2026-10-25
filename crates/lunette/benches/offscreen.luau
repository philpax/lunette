-- Owns the benchmark's real offscreen targets, client textures, submissions, and pixel validation.
local lunette = require '@lunette'

local offscreen = {}

-- Software rendering is the reproducible comparison; hardware rendering measures a device's own driver.
export type Driver = 'software' | 'hardware'

function offscreen.new(driver: Driver): any
  local graphics, data = lovr.graphics, lovr.data
  local resources = {}
  local closed = false
  local clients = {}
  local alternate = false
  local pass, target
  local details = {
    device = graphics.getDevice().name,
    width = 960,
    height = 640,
    draws = 0,
    drawsCulled = 0,
    nonBackgroundPixels = 0,
    changedTexturePixels = 0,
    glyphWarmFrames = 0,
    validated = false,
  }
  local renderer = { details = details }

  local function own(resource: any): any
    resources[#resources + 1] = resource
    return resource
  end

  local function release(resource: any): ()
    resource:release()
    for index, held in resources do
      if held == resource then
        table.remove(resources, index)
        return
      end
    end
    error('benchmark graphics: released an unowned resource', 0)
  end

  function renderer.close(): ()
    if closed then
      return
    end
    closed = true
    local failures = {}
    local function attempt(operation: () -> ()): ()
      local ok, failure = pcall(operation)
      if not ok then
        failures[#failures + 1] = tostring(failure)
      end
    end
    attempt(function(): ()
      graphics.submit()
    end)
    attempt(function(): ()
      graphics.wait()
    end)
    for index = #resources, 1, -1 do
      local resource = resources[index]
      attempt(function(): ()
        resource:release()
      end)
      resources[index] = nil
    end
    table.clear(clients)
    attempt(function(): ()
      graphics.submit()
    end)
    attempt(function(): ()
      graphics.wait()
    end)
    assert(#failures == 0, 'benchmark graphics cleanup: ' .. table.concat(failures, '; '))
  end

  local ok, failure = pcall(function(): ()
    if driver == 'software' then
      assert(details.device:lower():find 'llvmpipe', 'benchmark graphics: device is not Mesa lavapipe')
    else
      assert(
        not details.device:lower():find 'llvmpipe',
        'benchmark graphics: hardware rendering selected Mesa lavapipe'
      )
    end
    target = own(graphics.newTexture(details.width, details.height, {
      format = 'rgba8',
      linear = true,
      samples = 1,
      mipmaps = false,
      usage = { 'render', 'transfer' },
      label = 'benchmark camera',
    }))
    local depth = own(graphics.newTexture(details.width, details.height, {
      format = 'd32f',
      usage = 'render',
      samples = 1,
      label = 'benchmark depth',
    }))
    pass = own(graphics.newPass { texture = target, depth = depth, samples = 1 })
  end)
  if not ok then
    local cleaned, problem = pcall(renderer.close)
    error(tostring(failure) .. (if cleaned then '' else '; ' .. tostring(problem)), 0)
  end

  function renderer.client(index: number, width: number, height: number): () -> Texture
    assert(not closed, 'benchmark graphics: renderer is closed')
    local textures = {}
    for palette = 1, 2 do
      local image = own(data.newImage(width, height, 'rgba8'))
      local color = if palette == 1 then { 0.85, 0.05 + index * 0.005, 0.15, 1 } else { 0.05, 0.75, 0.9, 1 }
      image:mapPixel(function(x: number, y: number): (number, number, number, number)
        local shade = if (math.floor(x / 64) + math.floor(y / 64)) % 2 == 0 then 1 else 0.55
        return color[1] * shade, color[2] * shade, color[3] * shade, 1
      end)
      textures[palette] = own(graphics.newTexture(image, {
        linear = true,
        mipmaps = false,
        usage = { 'sample', 'transfer' },
        label = `benchmark client {index}, palette {palette}`,
      }))
      release(image)
    end
    clients[index] = textures
    return function(): Texture
      return textures[if alternate then 2 else 1]
    end
  end

  function renderer.prepare(): Pass
    assert(not closed, 'benchmark graphics: renderer is closed')
    pass:reset()
    pass:setClear(0.02, 0.02, 0.03, 1)
    local view = lovr.math.mat4():target(vector.pack(0, 1.5, 0.6), vector.pack(0, 1.4, -1.5), vector.pack(0, 1, 0))
    pass:setViewPose(1, view)
    pass:setProjection(1, lovr.math.mat4():perspective(math.rad(100), details.width / details.height, 0.01, 0))
    return pass
  end

  function renderer.submit(cpuClock: (() -> number)?): (number, number, number)
    local started = os.clock()
    local cpuStarted = if cpuClock then cpuClock() else 0
    assert(graphics.submit(pass), 'benchmark graphics: submission failed')
    local cpuElapsed = if cpuClock then (cpuClock() - cpuStarted) * 1e6 else 0
    local elapsed = (os.clock() - started) * 1e6
    local waiting = os.clock()
    graphics.wait()
    return elapsed, cpuElapsed, (os.clock() - waiting) * 1e6
  end

  function renderer.stats(): ()
    local stats = pass:getStats()
    details.draws = stats.draws
    details.drawsCulled = stats.drawsCulled
    assert(details.draws > 0, 'benchmark graphics: pass contains no draws')
    assert(details.draws > details.drawsCulled, 'benchmark graphics: every draw was culled')
  end

  local function read(): Image
    local readback = own(target:newReadback())
    assert(graphics.submit {}, 'benchmark graphics: readback submission failed')
    readback:wait()
    assert(readback:isComplete(), 'benchmark graphics: readback is incomplete')
    local image = own(assert(readback:getImage(), 'benchmark graphics: readback has no image'))
    release(readback)
    return image
  end

  function renderer.ready(render: () -> (), healthy: () -> ()): ()
    assert(not closed, 'benchmark graphics: renderer is closed')
    details.validated = false
    details.glyphWarmFrames = 0
    alternate = false
    local atlas = lunette.glyphAtlas()
    local deadline = os.clock() + 30
    repeat
      assert(os.clock() < deadline, 'benchmark graphics: glyph generation did not finish')
      render()
      healthy()
      details.glyphWarmFrames += 1
    until atlas.pending == 0
    -- A completed worker may place a glyph after the preceding draw has skipped it.
    render()
    healthy()
    renderer.stats()
    local original = read()
    alternate = true
    render()
    healthy()
    local changed = read()
    local nonBackground, textured = 0, 0
    for y = 0, details.height - 1, 2 do
      for x = 0, details.width - 1, 2 do
        local r, g, b = original:getPixel(x, y)
        local cr, cg, cb = changed:getPixel(x, y)
        if math.max(math.abs(r - 0.02), math.abs(g - 0.02), math.abs(b - 0.03)) > 0.03 then
          nonBackground += 1
        end
        if math.max(math.abs(r - cr), math.abs(g - cg), math.abs(b - cb)) > 0.1 then
          textured += 1
        end
      end
    end
    release(changed)
    release(original)
    alternate = false
    render()
    healthy()
    renderer.stats()
    assert(atlas.pending == 0, 'benchmark graphics: glyph generation resumed during validation')
    assert(nonBackground > 100, 'benchmark graphics: camera contains no scene pixels')
    -- The difference proves client texture contribution, not visibility of every overlapping client.
    assert(textured > 100, 'benchmark graphics: client textures do not affect the camera pixels')
    details.nonBackgroundPixels = nonBackground
    details.changedTexturePixels = textured
    details.validated = true
  end

  function renderer.validate(): ()
    renderer.stats()
    assert(details.validated, 'benchmark graphics: readiness has not validated the camera')
    assert(lunette.glyphAtlas().pending == 0, 'benchmark graphics: glyphs are still pending')
  end

  return renderer
end

return offscreen
