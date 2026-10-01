-- Only native resources, LÖVR devices, the clock, and the filesystem are substituted.
local native = require '@lunette'
events = {
  subscriptions = {},
  claims = {},
  seats = {},
  windows = {},
  monitors = {},
  spawned = {},
  input = {},
  draw = {},
  logs = {},
  timeline = {},
  held = {},
  reads = 0,
  writes = 0,
  enumerations = 0,
  closed = 0,
  writeMode = 'ok',
  time = 0,
}
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
function emit(name, event)
  for _, record in ipairs(table.clone(events.subscriptions[name] or {})) do
    if record.active then
      record.callback(event)
    end
  end
end
function subscriptionCount(name)
  local count = 0
  for _, record in ipairs(events.subscriptions[name] or {}) do
    if record.active then
      count += 1
    end
  end
  return count
end
-- The native reload clears subscriptions after the plugin runtimes have shut
-- down. A subscription still live at that point is one a plugin forgot to
-- cancel, so it is a failure rather than something to clear.
function clearSubscriptions()
  for name in pairs(events.subscriptions) do
    assert(subscriptionCount(name) == 0, 'subscription outlived plugin shutdown: ' .. name)
  end
  forgetSubscriptions()
end
function forgetSubscriptions()
  for _, list in pairs(events.subscriptions) do
    for _, record in ipairs(list) do
      record.active = false
    end
  end
end
for _, name in ipairs { 'onWindowOpened', 'onWindowClosed', 'onProcessExited', 'onMonitorAdded', 'onError' } do
  native[name] = function(callback)
    return subscribe(name, callback)
  end
end
-- The native boundary logs a reported error and notifies every onError
-- listener; the fake records the report as the log and notifies the same way.
events.reported = {}
native.reportError = function(fields)
  local report = { message = fields.context .. ': ' .. fields.message, traceback = fields.traceback or '' }
  events.reported[#events.reported + 1] = report
  emit('onError', report)
end
native.windows = function()
  events.enumerations += 1
  assert(subscriptionCount 'onWindowOpened' > 0, 'subscribe before window enumeration')
  return table.clone(events.windows)
end
native.monitors = function()
  return events.monitors
end
native.seats = function()
  return events.seats
end
native.spawn = function(options)
  local process = { id = #events.spawned + 1, argv = options.argv, dead = false }
  events.spawned[#events.spawned + 1] = process
  return process
end
native.newSeat = function(name)
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
native.claimLayer = function(options)
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
local vectorMeta = {}
function vectorMeta.__index(value, key)
  if key == 'length' then
    return function(self)
      return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2)
    end
  end
  if key == 'unpack' then
    return function(self)
      return self.x, self.y, self.z
    end
  end
  if key == 'normalize' then
    return function(self)
      local length = self:length()
      self.x, self.y, self.z = self.x / length, self.y / length, self.z / length
      return self
    end
  end
end
function vectorMeta.__mul(value, scale)
  return setmetatable({ x = value.x * scale, y = value.y * scale, z = value.z * scale }, vectorMeta)
end
vector = {
  pack = function(x, y, z)
    return setmetatable({ x = x, y = y or x, z = z or x }, vectorMeta)
  end,
}
local function matrix(...)
  local matrix = { elements = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } }
  function matrix:set(...)
    local first = ...
    self.elements = if type(first) == 'table' then table.clone(first.elements) else { ... }
    return self
  end
  function matrix:translate(x, y, z)
    self.elements[13] += x
    self.elements[14] += y
    self.elements[15] += z
    return self
  end
  function matrix:rotate()
    return self
  end
  function matrix:scale()
    return self
  end
  function matrix:unpack()
    return table.unpack(self.elements)
  end
  function matrix:getPosition()
    return self.elements[13], self.elements[14], self.elements[15]
  end
  function matrix:getOrientation()
    return 0, 0, 1, 0
  end
  function matrix:invert()
    self.elements[13] *= -1
    self.elements[14] *= -1
    self.elements[15] *= -1
    return self
  end
  function matrix:mul(x, y, z, w)
    if type(x) == 'table' then
      return self
    end
    return x + self.elements[13] * w, y + self.elements[14] * w, z + self.elements[15] * w
  end
  local first = ...
  if type(first) == 'table' then
    matrix:set(first)
  elseif type(first) == 'number' then
    local x, y, z = ...
    matrix:translate(x, y, z)
  end
  return matrix
end
lovr = {
  math = { newMat4 = matrix, mat4 = matrix },
  graphics = {},
  timer = {
    getTime = function()
      return events.time
    end,
  },
  system = {
    isKeyDown = function(key)
      return events.held[key] == true
    end,
  },
  headset = {
    isTracked = function()
      return true
    end,
    -- The left hand is held aside so only the right beam reaches the panels
    -- in front; events.handX moves both hands.
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
  },
  filesystem = {
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
  },
  log = function(message, level, tag)
    events.logs[#events.logs + 1] = { message, level, tag }
  end,
}
local pass = {}
for _, name in ipairs {
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
} do
  pass[name] = function(_, ...)
    events.draw[#events.draw + 1] = { name, ... }
  end
end
events.pass = pass
function newWindow(id, appId)
  local window = {
    id = id,
    appId = appId or 'terminal',
    title = 'Fixture window',
    dead = false,
    width = 1000,
    height = 500,
    properties = {},
  }
  local sink = { domain = 'window' }
  for _, name in ipairs { 'key', 'modifiers', 'pointer', 'motion', 'button', 'scroll', 'enter', 'leave' } do
    sink[name] = function(_, ...)
      events.input[#events.input + 1] = { name, ... }
      return true
    end
  end
  window.sink = sink
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
function newMonitor(id)
  local sink = { domain = 'host' }
  for _, name in ipairs { 'key', 'modifiers', 'pointer', 'motion', 'button', 'scroll', 'enter', 'leave' } do
    sink[name] = function(_, ...)
      events.input[#events.input + 1] = { name, ... }
      return true
    end
  end
  local monitor = { id = id, name = id, dead = false, width = 1920, height = 1080, sink = sink }
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
  return monitor
end
function assertResourcesReleased()
  for _, seat in ipairs(events.seats) do
    assert(seat.dead, 'leaked native seat')
  end
  for _, claim in ipairs(events.claims) do
    assert(claim.dead, 'leaked native claim')
  end
  for name in pairs(events.subscriptions) do
    assert(subscriptionCount(name) == 0, 'leaked subscription: ' .. name)
  end
  assert(events.closed == 0, 'cleanup closed caller-owned window')
end
