-- Deterministic desktop update/draw and production picking workloads for the hardware-free benchmark runner.
local scene = {}

function scene.setup(offscreen: boolean?, cpuClock: (() -> number)?): any
  return require('./session').new(offscreen, cpuClock)
end

function scene.prepareEpoch(stable: any): any
  assert(not stable.closed, 'benchmark: session is closed')
  local fake, renderer, cpuClock = stable.fake, stable.renderer, stable.cpuClock
  fake.assertResourcesReleased()
  local events = fake.events
  -- Disposed fake records retain callbacks until their inspection history is cleared.
  table.clear(events.subscriptions)
  table.clear(events.seats)
  table.clear(events.claims)
  table.clear(events.audio)
  table.clear(events.files)
  events.saved, events.time, events.frameGeneration = nil, 0, 0
  for _, window in events.windows do
    table.clear(window.properties)
    window.commit = 0
  end
  local clientTextures = stable.clientTextures
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
  local recorder = uiPanels.new()
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
  local sessionClosed = false
  local session = {
    runtime = running.runtime,
    close = function(): ()
      if sessionClosed then
        return
      end
      sessionClosed = true
      local released, failure = pcall(function(): ()
        running.runtime:close()
      end)
      local checked, problem = pcall(fake.assertResourcesReleased)
      if not released or not checked then
        error((if released then '' else tostring(failure)) .. (if checked then '' else '; ' .. tostring(problem)), 0)
      end
    end,
  }
  local closed = false
  local workload = {
    panels = 0,
    windows = 8,
    label = 'development desktop, all panels, eight client windows, two moving hands',
    renderer = if renderer then 'offscreen' else 'recorded',
    rendering = if renderer then renderer.details else nil,
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
      closed = true
      session:close()
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
    local released, failure = pcall(workload.close)
    error(tostring(problem) .. (if released then '' else '; benchmark cleanup: ' .. tostring(failure)), 0)
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
    nativeProbe: (() -> boolean)?,
    profileBoundary: ((string, boolean) -> ())?
  ): (number, number, boolean?, boolean?, boolean?, number, number, number, number, number)
    local executingNative = if nativeProbe then nativeProbe() else nil
    assert(not closed, 'benchmark: workload is closed')
    local afterAssertNative = if nativeProbe then nativeProbe() else nil
    local pose = poses[(index - 1) % #poses + 1]
    fixture:pose('left', pose.left)
    fixture:pose('right', pose.right)
    for number, window in events.windows do
      window.commit = math.floor(index / (number % 3 + 1))
    end
    local framePass = if renderer then renderer.prepare() else pass
    local before = events.textures or 0
    fake.advanceFrame(1 / 90)
    if profileBoundary then
      profileBoundary('update', true)
    end
    local started = os.clock()
    local updateCpuStarted = if cpuClock then cpuClock() else 0
    update(1 / 90)
    local updateCpu = if cpuClock then (cpuClock() - updateCpuStarted) * 1e6 else 0
    local updated = os.clock()
    if profileBoundary then
      profileBoundary('update', false)
      profileBoundary('draw', true)
    end
    local drawing = os.clock()
    local drawCpuStarted = if cpuClock then cpuClock() else 0
    local discarded = draw(framePass)
    local drawCpu = if cpuClock then (cpuClock() - drawCpuStarted) * 1e6 else 0
    local drawn = os.clock()
    if profileBoundary then
      profileBoundary('draw', false)
    end
    local afterDrawNative = if nativeProbe then nativeProbe() else nil
    assert(discarded == false, 'benchmark: draw vetoed the pass')
    local submitted, submitCpu, waited = 0, 0, 0
    if renderer then
      submitted, submitCpu, waited = renderer.submit(cpuClock)
      renderer.stats()
    else
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
      sawDraw = sawDraw or draws > 0
      sawText = sawText or text > 0
      sawMeshes = sawMeshes or meshes > 0
    end
    textures = (events.textures or 0) - before
    frames += 1
    sawWindows = sawWindows or textures == 8
    clearTraces()
    lovr.math.drain()
    return (updated - started) * 1e6,
      (drawn - drawing) * 1e6,
      executingNative,
      afterDrawNative,
      afterAssertNative,
      updateCpu,
      drawCpu,
      submitted,
      submitCpu,
      waited
  end

  workload.validate = function(): ()
    healthy()
    assert(frames > 0 and sawWindows and textures == 8, 'benchmark: missing window texture retrievals')
    if renderer then
      renderer.validate()
    else
      assert(draws > 0 and text > 0 and meshes > 0, 'benchmark: missing desktop drawing')
      assert(sawDraw and sawText and sawMeshes, 'benchmark: missing window drawing')
    end
    assert(#events.windows == 8 and #windowPanels:all() == 8, 'benchmark: wrong adopted window count')
    for index, window in events.windows do
      if not renderer then
        assert(contentDraws[index], `benchmark: client window {index} content was not drawn`)
      end
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

  workload.ready = function(): ()
    workload.frame(1)
    if renderer then
      -- Freeze simulation time so only the client textures change between the paired readbacks.
      renderer.ready(function(): ()
        local framePass = renderer.prepare()
        local before = events.textures or 0
        assert(draw(framePass) == false, 'benchmark: draw vetoed the pass')
        renderer.submit()
        textures = (events.textures or 0) - before
        clearTraces()
        lovr.math.drain()
      end, healthy)
    end
    workload.validate()
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
  workload.selectedProbe = function(callback: (any, vector, vector) -> (number, number, number)): ()
    assert(not closed, 'benchmark: workload is closed')
    local target = { dead = false, pickPriority = 0, raycast = callback }
    local hit = picking.pick({ target }, vector.pack(0, 0, 0), vector.pack(0, 0, -1), 4)
    assert(hit == target, 'benchmark: selected picking probe missed')
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

  workload.ready()
  return workload
end

return scene
