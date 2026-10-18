-- Deterministic desktop update/draw and production picking workloads for the hardware-free benchmark runner.
local native = require '@testing/native'

local scene = {}

local prepare: (native.Fake, (any) -> ()) -> any

function scene.setup(): any
  -- Install fake functions before loading modules whose optimized imports may otherwise capture native functions.
  local fake = native.new()
  local originalDate = os.date
  os.date = function(_format: string?, _time: number?): string
    return '12:00'
  end
  local session
  local ok, workload = pcall(function(): any
    local result = prepare(fake, function(running: any): ()
      session = running
    end)
    result.validate()
    return result
  end)
  if not ok then
    os.date = originalDate
    if session then
      local released, failure = pcall(function(): ()
        session:close()
      end)
      assert(released, `{workload}; benchmark cleanup: {failure}`)
    end
    error(workload, 0)
  end
  local close = workload.close
  workload.close = function(): ()
    local released, failure = pcall(close)
    os.date = originalDate
    if not released then
      error(failure, 0)
    end
  end
  return workload
end

prepare = function(fake: native.Fake, started: (any) -> ()): any
  local testing = require '@testing'
  testing.host.useConfiguration 'dev'
  local desktop = require '@lunette-desktop'
  local demoTerminal = require 'plugins/demo-terminal'
  local uiGallery = require 'plugins/ui-gallery'
  local vrUi = require '@testing/vr-ui'
  local uiPanels = require '@testing/ui-panels'
  local wristMenu = require '@testing/wrist-menu'
  local uiHost = require '@lunette-contracts/ui-host'
  local panels = require '@lunette-contracts/panels'
  local keyboardDisplay = require '@lunette-contracts/keyboard-display'
  local picking = require '@lunette-plugins/interaction/picking'
  local shape = require '@lunette-plugins/panels/service/private/shape'
  local management = require '@lunette-plugin/management'
  local adapter = require '@lunette-plugin/adapter'
  local frame = require '@lunette-plugins/session/frame'
  local events = fake.events
  local recorder = uiPanels.new()
  local clientTextures = {}
  for index = 1, 8 do
    local window = fake.newWindow(index, `org.fixture.Window{index}`)
    window.title = `Benchmark window {index}`
    window.width = 960 + index * 32
    window.height = 540 + index * 16
    local texture = {
      name = `benchmark client {index}`,
      getDimensions = function(): (number, number)
        return window.width, window.height
      end,
    }
    clientTextures[texture] = index
    window.getTexture = function(): any
      events.textures = (events.textures or 0) + 1
      return texture
    end
    events.windows[index] = window
  end
  local fixture = vrUi.attach(fake)
  local host, windowPanels, display
  local observer = adapter.define {
    name = 'benchmark/observer',
    requires = { uiHost.capability, panels.capability, keyboardDisplay.capability },
    init = function(context: adapter.Context): ()
      host = context:require(uiHost.capability)
      windowPanels = context:require(panels.capability)
      display = context:require(keyboardDisplay.capability)
    end,
  }
  local running
  frame.install {
    start = function(): () end,
    stop = function(): ()
      running.runtime:close()
    end,
  }
  running = management.start(
    desktop.compose {
      patches = {
        recorder.entry,
        { insert = { id = 'dev/demo-terminal', definition = demoTerminal.definition }, after = 'desktop/adoption' },
        { insert = { id = 'dev/ui-gallery', definition = uiGallery.definition }, after = 'dev/demo-terminal' },
        { insert = { id = 'benchmark/observer', definition = observer } },
      },
    },
    {
      protected = {
        'desktop/manager',
        'desktop/menu',
        'desktop/keyboard',
        'desktop/pointing',
        'desktop/actions',
        'diagnostics/recovery',
      },
      reconfigurable = { 'ui-host', 'ui-standard' },
    }
  )
  local session = {
    runtime = running.runtime,
    close = function(): ()
      running.runtime:close()
      fake.assertResourcesReleased()
    end,
  }
  started(session)
  local closed = false
  local workload = {
    panels = 0,
    windows = 8,
    label = 'development desktop, all panels, eight client windows, two moving hands',
  }

  local function retainLive(resources: { any }): ()
    local count = 0
    for _, resource in resources do
      if not resource.released then
        count += 1
        resources[count] = resource
      end
    end
    for index = #resources, count + 1, -1 do
      resources[index] = nil
    end
  end

  local function clearTraces(): ()
    table.clear(events.draw)
    table.clear(events.input)
    table.clear(events.logs)
    table.clear(events.rates)
    table.clear(events.modes)
    table.clear(events.pauses)
    table.clear(events.render.fontMeasurements)
    table.clear(events.render.meshReleases)
    table.clear(events.render.shaderReleases)
    -- Keep live acquisitions for the recorder's teardown checks without retaining released resources.
    retainLive(events.render.meshAcquisitions)
    retainLive(events.render.shaderAcquisitions)
    retainLive(events.render.textureAcquisitions)
  end

  local function healthy(): ()
    assert(not closed, 'benchmark: workload is closed')
    for _, instance in session.runtime:snapshot().instances do
      assert(instance.state == 'active', `benchmark: plugin {instance.name} is {instance.state}: {instance.diagnostic}`)
    end
    assert(#events.reported == 0, 'benchmark: native error report')
    local reports = testing.takeReports()
    assert(#reports == 0, `benchmark: plugin report: {reports[1]}`)
  end

  workload.close = function(): ()
    if not closed then
      session:close()
      closed = true
    end
  end

  local ok, problem = pcall(function(): any
    fixture:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
    fixture:tracked('left', true)
    fixture:step(1 / 90)
    for _, action in
      {
        'desktop/accessibility',
        'desktop/manager/open',
        'desktop/backdrop/open',
        'desktop/keyboard/toggle',
        'dev/ui-gallery/open',
      }
    do
      wristMenu.run(fixture, recorder, action)
      healthy()
      clearTraces()
    end
    -- Spread overlapping panels before addressing the manager, so the other panels cannot intercept its ray.
    for _, placement in
      {
        { 'Accessibility', -0.95, 1.6, -1.25 },
        { 'desktop/manager', 0, 1.6, -1.5 },
        { 'desktop/backdrop/controls', 0.95, 1.6, -1.25 },
        { 'Widget gallery', 0.55, 0.95, -1 },
      }
    do
      local panel = assert(recorder:panel(placement[1]))
      panel:setPose(lovr.math.newMat4():translate(placement[2], placement[3], placement[4]))
    end
    recorder:click(fixture, 'desktop/manager', 'main/browser/entries-box/entries/' .. uiHost.keyOf 'dev/ui-gallery')
    recorder:click(fixture, 'desktop/manager', 'main/sidebar/tabs/track/configure')
    fixture:tracked('right', true)
    fixture:button('left', 'trigger', false)
    fixture:button('right', 'trigger', false)
    fixture:axis('left', 0, 0)
    fixture:axis('right', 0, 0)
    fixture:step(1 / 90)
  end)
  if not ok then
    workload.close()
    error(problem, 0)
  end

  local expected = {
    ['notifications'] = true,
    ['desktop/menu'] = true,
    ['Accessibility'] = true,
    ['desktop/manager'] = true,
    ['desktop/backdrop/controls'] = true,
    ['desktop/keyboard/titlebar'] = true,
    ['Widget gallery'] = true,
  }
  for index = 1, 8 do
    expected[`desktop/decorations/window/{index}`] = true
  end
  for _ in expected do
    workload.panels += 1
  end
  local outletPath = 'main/sidebar/configure/settings/' .. uiHost.keyOf 'dev/ui-gallery' .. '/body/gallery/about'
  local poses = {}
  for index = 1, 360 do
    local phase = (index - 1) * math.pi / 180
    poses[index] = {
      left = lovr.math.newMat4():translate(-0.35 + 0.12 * math.sin(phase), 1.15, -0.4),
      right = lovr.math
        .newMat4()
        :translate(0.28 * math.sin(phase), 1.45 + 0.18 * math.cos(phase), 0.1)
        :rotate(0.65 * math.sin(phase), 0, 1, 0),
    }
  end
  local draws, text, meshes, textures = 0, 0, 0, 0
  local contentDraws = table.create(8, false)
  local frames = 0
  local sawDraw, sawText, sawMeshes, sawWindows = false, false, false, false
  local update, draw = lovr.update, lovr.draw
  local pass = events.pass
  clearTraces()

  workload.frame = function(
    index: number,
    nativeProbe: (() -> boolean)?
  ): (number, number, boolean?, boolean?, boolean?)
    local executingNative = if nativeProbe then nativeProbe() else nil
    assert(not closed, 'benchmark: workload is closed')
    local afterAssertNative = if nativeProbe then nativeProbe() else nil
    local pose = poses[(index - 1) % #poses + 1]
    fixture:pose('left', pose.left)
    fixture:pose('right', pose.right)
    for number, window in events.windows do
      window.commit = math.floor(index / (number % 3 + 1))
    end
    local before = events.textures or 0
    fake.advanceFrame(1 / 90)
    local started = os.clock()
    update(1 / 90)
    local updated = os.clock()
    local discarded = draw(pass)
    local afterDrawNative = if nativeProbe then nativeProbe() else nil
    local drawn = os.clock()
    assert(discarded == false, 'benchmark: draw vetoed the pass')
    draws, text, meshes = #events.draw, 0, 0
    table.clear(contentDraws)
    for _, call in events.draw do
      if call[1] == 'draw' or call[1] == 'plane' then
        local material = call.state.setMaterial
        local window = material and clientTextures[material[1]]
        if window then
          contentDraws[window] = true
        end
      end
      if call[1] == 'text' then
        text += 1
      elseif call[1] == 'draw' then
        meshes += 1
      end
    end
    textures = (events.textures or 0) - before
    frames += 1
    sawDraw = sawDraw or draws > 0
    sawText = sawText or text > 0
    sawMeshes = sawMeshes or meshes > 0
    sawWindows = sawWindows or textures == 8
    clearTraces()
    lovr.math.drain()
    return (updated - started) * 1e6, (drawn - updated) * 1e6, executingNative, afterDrawNative, afterAssertNative
  end

  workload.validate = function(): ()
    healthy()
    assert(frames > 0 and draws > 0 and text > 0 and meshes > 0, 'benchmark: missing desktop drawing')
    assert(sawDraw and sawText and sawMeshes and sawWindows and textures == 8, 'benchmark: missing window drawing')
    assert(#events.windows == 8 and #windowPanels:all() == 8, 'benchmark: wrong adopted window count')
    for index, window in events.windows do
      assert(contentDraws[index], `benchmark: client window {index} content was not drawn`)
      local panel = assert(windowPanels:forSource(window), 'benchmark: window was not adopted')
      assert(panel.kind == 'window' and not panel.dead and not panel.hidden, 'benchmark: window is not visible')
    end
    assert(display:isVisible(), 'benchmark: keyboard is hidden')
    local visible = {}
    for _, registration in host:inspect().registrations do
      if registration.kind == 'panel' and registration.live and registration.details.visible then
        assert(expected[registration.name], `benchmark: unexpected visible panel {registration.name}`)
        assert(not visible[registration.name], `benchmark: duplicate visible panel {registration.name}`)
        visible[registration.name] = true
      end
    end
    for name in expected do
      assert(visible[name], `benchmark: missing visible panel {name}`)
    end
    assert(recorder:node('desktop/manager', outletPath), 'benchmark: gallery settings outlet is not mounted')
    assert(#events.draw == 0 and #events.input == 0, 'benchmark: frame traces were retained')
    assert(#events.render.fontMeasurements == 0, 'benchmark: font measurement traces were retained')
  end

  local targets = {}
  for index = 1, 8 do
    local target = {
      pose = lovr.math.newMat4():translate((index - 4.5) * 0.6, 1.5, -2),
      width = 0.5,
      height = 0.7,
      pixelWidth = 1000,
      pixelHeight = 700,
      curve = if index % 2 == 0 then 0.8 else 0,
      dead = false,
      pickPriority = index % 3,
    }
    target.raycast = function(self: any, origin: vector, direction: vector): (number?, number?, number?)
      return shape.hit(self, origin, direction)
    end
    targets[index] = target
  end
  local rays = {}
  for index = 1, 32 do
    local target = (index - 1) % #targets + 1
    rays[index] = {
      origin = vector.pack((target - 4.5) * 0.6, if index % 4 < 2 then 1.5 else 3, 0),
      direction = vector.pack(0, 0, -1),
    }
  end
  workload.micro = function(iterations: number, nativeProbe: (() -> boolean)?): (number, boolean?, boolean?, boolean?)
    local executingNative = if nativeProbe then nativeProbe() else nil
    assert(not closed, 'benchmark: workload is closed')
    local afterAssertNative = if nativeProbe then nativeProbe() else nil
    assert(iterations >= 2 and iterations % 1 == 0, 'benchmark: micro needs at least two integer iterations')
    local checksum, hits, misses = 0, 0, 0
    for index = 1, iterations do
      local ray = rays[(index - 1) % #rays + 1]
      local hit, x, y, distance = picking.pick(targets, ray.origin, ray.direction, 4)
      if hit then
        hits += 1
        checksum += x * 0.001 + y * 0.002 + distance + hit.curve
      else
        misses += 1
        checksum += 0.125
      end
      lovr.math.drain()
    end
    local afterGeometryNative = if nativeProbe then nativeProbe() else nil
    assert(hits > 0 and misses > 0, 'benchmark: micro needs both hits and misses')
    assert(checksum > 0 and checksum < math.huge, 'benchmark: invalid geometry checksum')
    return checksum, executingNative, afterGeometryNative, afterAssertNative
  end

  workload.frame(1)
  return workload, session
end

return scene
