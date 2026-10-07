local lunette = require '@lunette'

local duration = 60
local maxFrames = 600
local elapsed = 0
local frameCount = 0
local graphicsSubmissions = 0
local headsetSubmissionsReturned = 0
local sceneEnabled = true
local movingPanel
local stereoPanel
local eyeShader
local lastPhase
local registrationPose = { 0, 1.9, -2, 0, 0, 1, 0 }
local registrationMarkers = {
  { label = 'TL', x = 40, y = 40 },
  { label = 'TR', x = 600, y = 40 },
  { label = 'CENTER', x = 320, y = 160 },
  { label = 'BL', x = 40, y = 280 },
  { label = 'BR', x = 600, y = 280 },
}

local function log(message)
  lovr.log('openvr diagnostic: ' .. message, 'info')
end

local function logTracking(phase)
  log(
    string.format(
      '%s: frame=%d focused=%s left-grip=%s left-point=%s right-grip=%s right-point=%s',
      phase,
      frameCount,
      tostring(lovr.headset.isFocused()),
      tostring(lovr.headset.isTracked 'hand/left/grip'),
      tostring(lovr.headset.isTracked 'hand/left/point'),
      tostring(lovr.headset.isTracked 'hand/right/grip'),
      tostring(lovr.headset.isTracked 'hand/right/point')
    )
  )
end

local function cleanup()
  lovr.headset.setLayers { main = false }
  lunette.setSceneEnabled(true)
  if movingPanel then
    movingPanel:release()
    movingPanel = nil
  end
  if stereoPanel then
    stereoPanel:release()
    stereoPanel = nil
  end
  if eyeShader then
    eyeShader:release()
    eyeShader = nil
  end
end

function lovr.load()
  local driver = lovr.headset.getDriver()
  if driver ~= 'SteamVR' then
    error(
      'openvr diagnostic: the explicitly requested OpenVR backend must report SteamVR; getDriver returned '
        .. tostring(driver)
        .. '; use an OpenVR-enabled lunette build, start SteamVR with a connected headset, and retry --config-path crates/lunette/tests/fixtures/openvr-diagnostic/lunette'
    )
  end
  lovr.graphics.setBackgroundColor(0, 0, 0, 0)
  movingPanel = lovr.headset.newLayer(640, 320, { static = false, transparent = true })
  movingPanel:setDimensions(1.2, 0.6)
  stereoPanel = lovr.headset.newLayer(640, 320, { stereo = true, static = false, transparent = true })
  stereoPanel:setDimensions(1.2, 0.6)
  stereoPanel:setPose(unpack(registrationPose))
  eyeShader = lovr.graphics.newShader(
    [[
      vec4 lovrmain() {
        return DefaultPosition;
      }
    ]],
    [[
      uniform float eyeFilter;
      vec4 lovrmain() {
        if (eyeFilter >= 0. && abs(float(ViewIndex) - eyeFilter) > .5) discard;
        vec3 tint = ViewIndex == 0 ? vec3(1., .25, .15) : vec3(.15, .8, 1.);
        return DefaultColor * vec4(tint, 1.);
      }
    ]],
    { flags = { colorTexture = true }, label = 'OpenVR diagnostic eye labels' }
  )
  lunette.setSceneEnabled(true)
  log 'manual observation only; 600 frames, 60-second timeout; Escape exits'
  log 'submission counts track API completion, not runtime presentation; scene PID is unavailable through the public API'
  log 'registration oracle: native red LEFT / cyan RIGHT squares and yellow scene crosses share pose (0, 1.9, -2), identity rotation, 1.2 x 0.6m; TL/TR/BL/BR/CENTER identify image orientation; observe alignment, no inversion applied'
end

function lovr.keypressed(key)
  if key == 'escape' then
    lovr.event.quit(0)
  end
end

function lovr.quit()
  cleanup()
end

function lovr.restart()
  cleanup()
end

local function drawMovingPanel()
  movingPanel:setPose(0.35 * math.sin(elapsed), 1, -1.7, 0.15 * math.sin(elapsed * 0.7), 0, 1, 0)
  local pass = movingPanel:getPass()
  pass:setClear(0, 0, 0, 0)
  pass:setColor(0.08, 0.15, 0.25, 1)
  pass:plane(320, 80, 0, 640, 160)
  pass:setColor(1, 1, 1, 1)
  pass:text(
    string.format('MUTABLE VULKAN PANEL\n%.1fs / %ds | frame %d', elapsed, duration, frameCount),
    320,
    70,
    0.1,
    24
  )
  pass:setColor(0.2, 1, 0.3, 1)
  pass:plane(320 + 260 * math.sin(elapsed * 3), 140, 0.1, 35, 20)
  pass:setColor(1, 0.6, 0.1, 0.5)
  pass:plane(160, 235, 0, 240, 110)
  pass:setColor(1, 1, 1, 1)
  pass:text('50% ALPHA', 160, 235, 0.1, 20)
  pass:text('CLEAR AREA', 480, 235, 0.1, 20)
  return pass
end

local function drawStereoPanel(phase)
  local pass = stereoPanel:getPass()
  pass:setClear(0, 0, 0, 0)
  pass:setShader(eyeShader)
  pass:send('eyeFilter', -1)
  pass:setColor(1, 1, 1, 1)
  pass:send('eyeFilter', 0)
  pass:text('LEFT EYE / RED', 320, 65, 0.1, 32)
  pass:send('eyeFilter', 1)
  pass:text('RIGHT EYE / CYAN', 320, 65, 0.1, 32)
  pass:send('eyeFilter', -1)
  pass:text(phase, 320, 110, 0.1, 22)
  pass:text(string.format('%.1fs | frame %d', elapsed, frameCount), 320, 195, 0.1, 22)
  pass:plane(320 + 270 * math.sin(elapsed * 2), 230, 0.1, 30, 25)
  for _, marker in registrationMarkers do
    pass:send('eyeFilter', -1)
    pass:plane(marker.x, marker.y, 0, 8, 8)
    pass:send('eyeFilter', 0)
    pass:text('L / ' .. marker.label, marker.x, marker.y + 16, 0, 14)
    pass:send('eyeFilter', 1)
    pass:text('R / ' .. marker.label, marker.x, marker.y + 16, 0, 14)
  end
  pass:setShader()
  return pass
end

local function drawScene(pass)
  pass:setClear(0, 0, 0, 0)
  pass:push()
  pass:translate(registrationPose[1], registrationPose[2], registrationPose[3])
  pass:setColor(1, 1, 0, 1)
  for _, marker in registrationMarkers do
    local x = (marker.x / 640 - 0.5) * 1.2
    local y = (0.5 - marker.y / 320) * 0.6
    pass:plane(x, y, 0, 0.06, 0.003)
    pass:plane(x, y, 0, 0.003, 0.06)
    pass:setShader(eyeShader)
    pass:send('eyeFilter', 0)
    pass:text('SCENE L / ' .. marker.label, x, y + 0.04, 0, 0.022)
    pass:send('eyeFilter', 1)
    pass:text('SCENE R / ' .. marker.label, x, y + 0.04, 0, 0.022)
    pass:setShader()
  end
  pass:pop()
  pass:setColor(0.2, 1, 0.3, 1)
  pass:box(-0.8, 1.3, -2.5, 0.3, 0.3, 0.3, elapsed, 0, 1, 0)
  pass:setColor(0.8, 0.3, 1, 1)
  pass:box(0.8, 1.3, -2.5, 0.3, 0.3, 0.3, -elapsed, 1, 0, 0)
  pass:setColor(1, 0.8, 0.2, 1)
  pass:box(0.4 * math.sin(elapsed), 1.3, -2.5, 0.025, 0.025, 1.5)
  pass:setColor(1, 1, 1, 1)
  pass:text('WORLD-SPACE SCENE', 0, 1.3, -3, 0.12)
end

function lovr.run()
  lovr.timer.step()
  lovr.load(arg)
  return function()
    lovr.headset.pollEvents()
    if lovr.system then
      lovr.system.pollEvents()
    end
    for name, a, b, c, d in lovr.event.poll() do
      if name == 'restart' then
        return 'restart', lovr.restart and lovr.restart()
      elseif name == 'quit' and (not lovr.quit or not lovr.quit(a)) then
        return a or 0
      elseif name ~= 'quit' and lovr.handlers[name] then
        lovr.handlers[name](a, b, c, d)
      end
    end
    lovr.headset.update()
    local dt = lovr.timer.step()
    if dt ~= dt or dt == math.huge or dt == -math.huge or dt < 0 then
      cleanup()
      error 'openvr diagnostic: timer returned a non-finite or negative frame delta'
    end
    elapsed += dt
    if elapsed >= duration then
      log(
        string.format(
          'timeout: frames=%d graphics=%d headset-returns=%d',
          frameCount,
          graphicsSubmissions,
          headsetSubmissionsReturned
        )
      )
      cleanup()
      error 'openvr diagnostic: 60-second timeout before 600 completed frames; check SteamVR readiness and headset connection'
    end
    frameCount += 1
    local progress = (frameCount - 1) / maxFrames
    local omitMoving = progress >= 1 / 6 and progress < 2 / 6 or progress >= 5 / 6
    local nextSceneEnabled = not (progress >= 3 / 6 and progress < 4 / 6)
    local phase = progress >= 5 / 6 and 'MOVING PANEL REMOVED'
      or omitMoving and 'MOVING PANEL OMITTED'
      or not sceneEnabled and 'SCENE OFF / PANELS LIVE'
      or 'SCENE ON / PANELS LIVE'
    if phase ~= lastPhase then
      logTracking(phase)
      lastPhase = phase
    end

    local layers = { stereoPanel, main = sceneEnabled }
    if not omitMoving then
      table.insert(layers, movingPanel)
    end
    lovr.headset.setLayers(layers)
    if progress >= 5 / 6 and movingPanel then
      movingPanel:release()
      movingPanel = nil
    end

    local passes = { drawStereoPanel(phase) }
    if not omitMoving then
      table.insert(passes, drawMovingPanel())
    end
    if sceneEnabled then
      local scene = lovr.headset.getPass()
      if scene then
        drawScene(scene)
        table.insert(passes, scene)
      end
    end
    lunette.setSceneEnabled(nextSceneEnabled)
    sceneEnabled = nextSceneEnabled
    if not lovr.graphics.submit(passes) then
      cleanup()
      error 'openvr diagnostic: graphics submission failed'
    end
    graphicsSubmissions += 1
    lovr.headset.submit()
    headsetSubmissionsReturned += 1
    lovr.graphics.present()
    if frameCount % 100 == 0 then
      logTracking(phase)
      log(
        string.format(
          'progress: frames=%d/%d graphics=%d headset-returns=%d elapsed=%.3fs',
          frameCount,
          maxFrames,
          graphicsSubmissions,
          headsetSubmissionsReturned,
          elapsed
        )
      )
    end
    if frameCount >= maxFrames then
      log 'bounded observation complete; verify presentation and scene PID externally; no hardware pass is asserted'
      lovr.event.quit(0)
    end
  end
end
