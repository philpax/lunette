-- Provides fake native APIs for tests. The plugin runtime, key and scale vocabularies, and `lovr.math` remain real.

local lunette = require '@lunette'
local host = require '@testing/host'

local native = {}

local installNative, installLovr

local SINK_METHODS = { 'key', 'modifiers', 'pointer', 'motion', 'button', 'scroll', 'enter', 'leave' }
local DRAW_METHODS = {
  'setColor',
  'plane',
  'text',
  'line',
  'sphere',
  'setDepthTest',
  'setDepthWrite',
  'setShader',
  'setMaterial',
  'setBlendMode',
  'roundrect',
  'draw',
}
local SUBSCRIPTIONS = { 'onWindowOpened', 'onWindowClosed', 'onProcessExited', 'onMonitorAdded', 'onError' }

function native.new()
  local fake = {}
  local events = {
    subscriptions = {},
    claims = {},
    seats = {},
    windows = {},
    monitors = {},
    outputs = {},
    spawned = {},
    input = {},
    draw = {},
    logs = {},
    timeline = {},
    held = {},
    reported = {},
    reads = 0,
    writes = 0,
    enumerations = 0,
    closed = 0,
    writeMode = 'ok',
    time = 0,
    rates = {},
    modes = {},
    pauses = {},
  }
  fake.events = events

  local function subscribe(name, callback)
    local list = events.subscriptions[name] or {}
    events.subscriptions[name] = list
    local record = { callback = callback, active = true }
    list[#list + 1] = record
    return function()
      assert(record.active, 'subscription disposed twice')
      record.active = false
    end
  end

  function fake.emit(name, event)
    for _, record in ipairs(table.clone(events.subscriptions[name] or {})) do
      if record.active then
        record.callback(event)
      end
    end
  end

  function fake.subscriptionCount(name)
    local count = 0
    for _, record in ipairs(events.subscriptions[name] or {}) do
      if record.active then
        count += 1
      end
    end
    return count
  end

  function fake.forgetSubscriptions()
    for _, list in pairs(events.subscriptions) do
      for _, record in ipairs(list) do
        record.active = false
      end
    end
  end

  function fake.raise(message, traceback)
    local listeners = {}
    for _, record in ipairs(events.subscriptions.onError or {}) do
      if record.active then
        listeners[#listeners + 1] = record.callback
      end
    end
    local logged = host.reportTraced(listeners, message, traceback)
    events.reported[#events.reported + 1] = { message = message, traceback = traceback, logged = logged }
    return logged
  end

  function fake.dropEndedSubscriptions()
    for name, list in pairs(events.subscriptions) do
      local live = {}
      for _, record in ipairs(list) do
        if record.active then
          live[#live + 1] = record
        end
      end
      events.subscriptions[name] = live
    end
  end

  -- Reload requires every plugin subscription to end before native subscriptions are cleared.
  local function clearSubscriptions()
    for name in pairs(events.subscriptions) do
      assert(fake.subscriptionCount(name) == 0, 'subscription outlived plugin shutdown: ' .. name)
    end
    fake.forgetSubscriptions()
  end

  function fake.newOutput(id, scale)
    local output = { id = id, dead = false, width = 1920, height = 1080, scale = scale or 1, refresh = 60 }
    function output:setMode(mode)
      events.modes[#events.modes + 1] = { output = self.id, scale = mode.scale }
      if mode.scale then
        self.scale = mode.scale
      end
      return true
    end
    return output
  end
  events.outputs[1] = fake.newOutput(1)

  local function newSink(domain)
    local sink = { domain = domain }
    for _, name in ipairs(SINK_METHODS) do
      sink[name] = function(_, ...)
        events.input[#events.input + 1] = { name, ... }
        return true
      end
    end
    return sink
  end

  function fake.newWindow(id, appId)
    local window = {
      id = id,
      appId = appId or 'terminal',
      title = 'Fixture window',
      dead = false,
      width = 1000,
      height = 500,
      properties = {},
      contentType = 'none',
      commit = 0,
      output = events.outputs[1],
      sink = newSink 'window',
    }
    function window:setFrameRate(rate)
      events.rates[#events.rates + 1] = { window = self.id, rate = rate }
      self.rate = rate
      return true
    end
    function window:getProperty(key)
      return self.properties[key]
    end
    function window:setProperty(key, value)
      self.properties[key] = value
      return true
    end
    function window:getTexture()
      events.textures = (events.textures or 0) + 1
      return nil
    end
    function window:close()
      events.closed += 1
      self.dead = true
      return true
    end
    return window
  end

  function fake.newMonitor(id)
    local monitor = { id = id, name = id, dead = false, width = 1920, height = 1080, sink = newSink 'host' }
    function monitor:mirror()
      events.mirrored = (events.mirrored or 0) + 1
      return true
    end
    function monitor:getTexture()
      return nil
    end
    function monitor:dismiss()
      events.unmirrored = (events.unmirrored or 0) + 1
      return true
    end
    function monitor:setPaused(paused)
      events.pauses[#events.pauses + 1] = { monitor = self.id, paused = paused }
      self.paused = paused
      return true
    end
    return monitor
  end

  -- Teardown releases every seat and claim, cancels every subscription, and leaves caller-owned windows open.
  function fake.assertResourcesReleased()
    for _, seat in ipairs(events.seats) do
      assert(seat.dead, 'leaked native seat')
    end
    for _, claim in ipairs(events.claims) do
      assert(claim.dead, 'leaked native claim')
    end
    for name in pairs(events.subscriptions) do
      assert(fake.subscriptionCount(name) == 0, 'leaked subscription: ' .. name)
    end
    assert(events.closed == 0, 'cleanup closed caller-owned window')
  end

  installNative(fake, events, subscribe, clearSubscriptions)
  installLovr(events)
  return fake
end

installNative = function(fake, events, subscribe, clearSubscriptions)
  for _, name in ipairs(SUBSCRIPTIONS) do
    lunette[name] = function(callback)
      return subscribe(name, callback)
    end
  end
  lunette.reportError = function(fields)
    fake.raise(fields.context .. ': ' .. fields.message, fields.traceback or '')
  end
  lunette.windows = function()
    events.enumerations += 1
    assert(fake.subscriptionCount 'onWindowOpened' > 0, 'subscribe before window enumeration')
    return table.clone(events.windows)
  end
  lunette.monitors = function()
    return events.monitors
  end
  lunette.outputs = function()
    return table.clone(events.outputs)
  end
  lunette.seats = function()
    return events.seats
  end
  lunette.spawn = function(options)
    local process = { id = #events.spawned + 1, argv = options.argv, dead = false }
    events.spawned[#events.spawned + 1] = process
    return process
  end
  lunette.newSeat = function(name)
    local seat = { id = #events.seats + 1, name = name, dead = false, layouts = { 'fixture' }, modifiers = {} }
    events.seats[#events.seats + 1] = seat
    function seat:setFocus(sink)
      self.focus = sink
      return true
    end
    function seat:strokeFor(text)
      if text == 'q' then
        return { keycode = 16, modifiers = {} }
      elseif text == 'Q' then
        return { keycode = 16, modifiers = { 'shift' } }
      end
      return nil
    end
    function seat:characterFor(code, modifiers)
      return if code == 16 then (if table.find(modifiers or {}, 'shift') then 'Q' else 'q') else nil
    end
    function seat:symbolFor(code)
      return code
    end
    function seat:setModifiers(modifiers)
      self.modifiers = modifiers or {}
      return true
    end
    function seat:destroy()
      if self.dead then
        return false
      end
      self.dead = true
      events.timeline[#events.timeline + 1] = 'seat disposed'
      return true
    end
    return seat
  end
  lunette.claimLayer = function(options)
    local claim = { dead = false, granted = false, layer = false, width = options.width, height = options.height }
    events.claims[#events.claims + 1] = claim
    function claim:release()
      if self.dead then
        return false
      end
      self.dead = true
      events.timeline[#events.timeline + 1] = 'claim disposed'
      return true
    end
    function claim:setPose()
      return true
    end
    function claim:setSize()
      return true
    end
    return claim
  end
  lunette.reload = function()
    return host.reload(clearSubscriptions)
  end
end

installLovr = function(events)
  lovr.graphics = {}
  lovr.timer = {
    getTime = function()
      return events.time
    end,
  }
  lovr.system = {
    isKeyDown = function(key)
      return events.held[key] == true
    end,
  }
  lovr.headset = {
    isTracked = function()
      return true
    end,
    -- The left hand stays outside the panel area so tests can isolate the right-hand beam.
    getPose = function(device)
      return (if device:find('left', 1, true) then -5 else 0) + (events.handX or 0), 1.5, 0, 0, 0, 1, 0
    end,
    getPosition = function(device)
      return (if device and device:find('left', 1, true) then -5 else 0) + (events.handX or 0), 1.5, 0
    end,
    getDirection = function()
      return 0, 0, -1
    end,
    isDown = function(_device, button)
      return (button == 'trigger' and events.trigger == true) or (button == 'grip' and events.grip == true)
    end,
    getDeltaTime = function()
      return 0.016
    end,
    getAxis = function()
      return 0, 0
    end,
    vibrate = function(device, strength, duration)
      events.haptics = (events.haptics or 0) + 1
      events.haptic = { device = device, strength = strength, duration = duration }
      return true
    end,
  }
  lovr.filesystem = {
    read = function()
      events.reads += 1
      return events.saved
    end,
    getSaveDirectory = function()
      return '/fixture'
    end,
    write = function(_, text)
      events.writes += 1
      events.timeline[#events.timeline + 1] = 'save'
      if events.writeMode == 'throw' then
        error 'filesystem write exception'
      end
      if events.writeMode == 'refuse' then
        return false
      end
      events.saved = text
      return true
    end,
  }
  lovr.log = function(message, level, tag)
    events.logs[#events.logs + 1] = { message, level, tag }
  end
  local pass = {}
  for _, name in ipairs(DRAW_METHODS) do
    pass[name] = function(_, ...)
      events.draw[#events.draw + 1] = { name, ... }
    end
  end
  events.pass = pass
end

return native
