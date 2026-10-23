-- Owns benchmark fixtures across production source reloads without retaining an epoch's scene module.
local native = require '@testing/native'
local host = require '@testing/host'
local lunette = require '@lunette'
local offscreen = require './offscreen'

local session = {}

-- Without a driver, the session records graphics calls in Lua instead of rendering.
function session.new(driver: offscreen.Driver?, cpuClock: (() -> number)?): any
  assert(host.benchmark == nil, 'benchmark: a session is already active')
  local original = {
    graphics = lovr.graphics,
    data = lovr.data,
    timer = lovr.timer,
    system = lovr.system,
    headset = lovr.headset,
    filesystem = lovr.filesystem,
    log = lovr.log,
  }
  local stable: any = { current = nil, closed = false, cpuClock = cpuClock, clientTextures = {} }
  host.benchmark = stable

  function stable.close(): ()
    if stable.closed then
      return
    end
    stable.closed = true
    stable.current = nil
    local failures = {}
    local function attempt(operation: () -> ()): ()
      local ok, failure = pcall(operation)
      if not ok then
        failures[#failures + 1] = tostring(failure)
      end
    end
    attempt(function(): ()
      local reports = host.shutdown()
      assert(#reports == 0, 'benchmark shutdown: ' .. table.concat(reports, '; '))
    end)
    if stable.fake then
      attempt(stable.fake.assertResourcesReleased)
      table.clear(stable.fake.events.subscriptions)
    end
    if stable.renderer then
      attempt(stable.renderer.close)
      stable.renderer = nil
    end
    lovr.graphics, lovr.data = original.graphics, original.data
    lovr.timer, lovr.system, lovr.headset = original.timer, original.system, original.headset
    lovr.filesystem, lovr.log = original.filesystem, original.log
    stable.fake = nil
    table.clear(stable.clientTextures)
    host.benchmark = nil
    assert(#failures == 0, 'benchmark cleanup: ' .. table.concat(failures, '; '))
  end

  function stable.reload(): any
    assert(not stable.closed, 'benchmark: session is closed')
    assert(stable.current, 'benchmark: no active workload')
    stable.current = nil
    host.useConfiguration 'crates/lunette/benches'
    -- The fake forwards to the production host reload with its subscription-disposal guard.
    local ok, failure = lunette.reload()
    assert(ok, 'benchmark source reload: ' .. tostring(failure))
    return assert(stable.current, 'benchmark: source reload did not prepare a workload')
  end

  local ok, failure = pcall(function(): ()
    -- Install the fake before optimized imports can capture the native boundary.
    stable.fake = native.new()
    if driver then
      assert(original.graphics and original.data, 'benchmark: offscreen mode needs real graphics and data')
      lovr.graphics, lovr.data = original.graphics, original.data
      stable.renderer = offscreen.new(driver)
    end
    local events = stable.fake.events
    for index = 1, 8 do
      local window = stable.fake.newWindow(index, `org.fixture.Window{index}`)
      window.title = `Benchmark window {index}`
      window.width = 960 + index * 32
      window.height = 540 + index * 16
      local texture = if stable.renderer
        then nil
        else {
          name = `benchmark client {index}`,
          getDimensions = function(): (number, number)
            return window.width, window.height
          end,
        }
      local getTexture = if stable.renderer
        then stable.renderer.client(index, window.width, window.height)
        else function(): any
          return texture
        end
      if texture then
        stable.clientTextures[texture] = index
      end
      window.getTexture = function(): any
        events.textures = (events.textures or 0) + 1
        return getTexture()
      end
      events.windows[index] = window
    end
    host.useConfiguration 'crates/lunette/benches'
    require 'main'
    assert(stable.current, 'benchmark: main did not prepare a workload')
  end)
  if not ok then
    local cleaned, problem = pcall(stable.close)
    error(tostring(failure) .. (if cleaned then '' else '; ' .. tostring(problem)), 0)
  end
  return stable
end

return session
