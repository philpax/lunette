-- GPU buffer and texture accounting across ten real renderer activation replacements.

local testing = require '@testing'
local aurora = require './support/aurora'
local pixels = require './support/pixels'
local test = testing.suite()
local expect = testing.expect

type Stats = { buffers: number, textures: number }

local function stats(): Stats
  aurora.collect()
  local measured = lovr.graphics.getStats()
  return { buffers = measured.bufferMemory, textures = measured.textureMemory }
end

local function warm(current: aurora.Fixture): pixels.ImageData
  aurora.settle(current)
  local first = pixels.read(aurora.capture(current))
  local second = pixels.read(aurora.capture(current))
  local summary = pixels.summary(first)
  expect.truthy(
    summary.nonblank > 0.5,
    string.format(
      'first acquired frame draws real pixels: nonblank %.6f, mean %.6f, alpha %.6f',
      summary.nonblank,
      summary.mean,
      summary.alpha
    )
  )
  expect.truthy(pixels.difference(first, second).color < 2 / 255, 'warm frames remain equivalent')
  return second
end

test('aurora_reload_memory_pixels', function(): ()
  aurora.withFixture({ motion = 0, response = 1 }, function(current: aurora.Fixture): ()
    local instance = current.session.instances['desktop/backdrop']
    local cold = stats()
    local warmImage = warm(current)
    local baseline = pixels.summary(warmImage)
    local liveBudget = stats()
    expect.truthy(liveBudget.buffers > cold.buffers, 'production indexed meshes allocate real GPU buffers')
    expect.near(baseline.alpha, 1, 1 / 255, 'warm sky covers the target')
    local heldContext = current.context
    instance:disable()
    current.session.runtime:drain()
    expect.falsy(heldContext:active(), 'old renderer context shuts down')
    -- Recorded draws retain meshes until reset, even after the owning context releases them.
    current.pass:reset()
    local released = stats()
    print(
      'aurora accounted bytes: cold/live/released buffers, textures',
      cold.buffers,
      liveBudget.buffers,
      released.buffers,
      cold.textures,
      liveBudget.textures,
      released.textures
    )
    expect.equal(released.buffers, cold.buffers, 'renderer releases its accounted buffers')
    expect.equal(released.textures, cold.textures, 'renderer releases its accounted textures')
    for cycle = 1, 10 do
      instance:enable()
      current.session.runtime:drain()
      expect.equal(instance:state(), 'active', 'reacquired activation')
      expect.truthy(current.context ~= heldContext and current.context:active(), 'fresh renderer context')
      heldContext = current.context
      local image = warm(current)
      local measured = pixels.summary(image)
      local live = stats()
      local difference = pixels.difference(warmImage, image)
      local detail = string.format(
        'cycle %d: alpha %.6f/%.6f, mean %.6f/%.6f, color %.6f, shape %.6f',
        cycle,
        measured.alpha,
        baseline.alpha,
        measured.mean,
        baseline.mean,
        difference.color,
        difference.shape
      )
      expect.truthy(
        difference.alpha < 2 / 255 and difference.color < 2 / 255,
        'reacquired production pixels remain equivalent; ' .. detail
      )
      expect.equal(live.buffers, liveBudget.buffers, 'stable accounted buffer budget at cycle ' .. cycle)
      expect.equal(live.textures, liveBudget.textures, 'stable accounted texture budget at cycle ' .. cycle)
      instance:disable()
      current.session.runtime:drain()
      expect.falsy(heldContext:active(), 'replacement shutdown')
      current.pass:reset()
      local gone = stats()
      expect.equal(gone.buffers, released.buffers, 'buffer budget returns after cycle ' .. cycle)
      expect.equal(gone.textures, released.textures, 'texture budget returns after cycle ' .. cycle)
    end
    -- These counters exclude shader objects, pipeline allocations/cache, driver heaps,
    -- and Lua tables. They do not measure total GPU memory.
  end)
end)

return test
