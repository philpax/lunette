-- Provides fake native APIs for tests. The plugin runtime, key and scale vocabularies, and `lovr.math` remain real.

local lunette = require '@lunette'
local host = require '@testing/host'
local render = require '@testing/render'

local native = {}

export type Sink = {
  domain: 'window' | 'host',
  key: (Sink, number, boolean, Seat?) -> boolean,
  setModifiers: (Sink, { lunette.ModifierName }?, Seat?) -> boolean,
  pointer: (Sink, number, number, Seat?) -> boolean,
  motion: (Sink, number, number, Seat?) -> boolean,
  button: (Sink, lunette.PointerButton, boolean, Seat?) -> boolean,
  scroll: (Sink, number, number, Seat?) -> boolean,
  enter: (Sink, ...unknown) -> boolean,
  leave: (Sink, Seat?) -> boolean,
}
export type Texture = render.TextureToken
export type DrawCall = render.Call
export type Font = render.Font
export type PluginContext = lunette.PluginContext
export type PluginDefinition = lunette.PluginDefinition
export type PluginInstance = lunette.PluginInstance
export type PluginRuntime = lunette.PluginRuntime
export type PluginState = lunette.PluginState
export type PointerButton = lunette.PointerButton
export type ModifierName = lunette.ModifierName
export type Drag = {
  dead: boolean,
  width: number,
  height: number,
  x: number,
  y: number,
  opaque: boolean,
  crop: { number },
  texture: Texture | string | false,
  read getTexture: (Drag) -> Texture | string | false,
  read getSourceCrop: (Drag) -> ...number,
}
export type Layer = {
  read setViewport: (Layer, number, number, number, number) -> (),
  read setPosition: (Layer, number, number, number) -> (),
  read setOrientation: (Layer, number, number, number, number) -> (),
  read setDimensions: (Layer, number, number) -> (),
  read setCurve: (Layer, number) -> (),
}
export type ChildSurface = {
  id: number,
  kind: 'popup' | 'subsurface',
  below: boolean,
  x: number,
  y: number,
  width: number,
  height: number,
  crop: lunette.Crop,
  texture: Texture?,
  opaque: boolean,
}
export type ProcessIdentity = { read id: number }
export type Output = {
  id: number,
  dead: boolean,
  width: number,
  height: number,
  scale: number,
  refresh: number,
  setMode: (Output, { read scale: number? }) -> boolean,
}
export type Window = {
  id: number,
  appId: string,
  title: string,
  dead: boolean,
  width: number,
  height: number,
  properties: { [string]: unknown },
  contentType: string,
  sourceCrop: { number },
  serverSideDecorations: boolean,
  commit: number,
  output: Output,
  sink: Sink,
  rate: number?,
  children: { ChildSurface }?,
  setFrameRate: (Window, number?) -> boolean,
  getProperty: (Window, string) -> unknown,
  setProperty: (Window, string, unknown) -> boolean,
  getTexture: (Window) -> Texture?,
  getSourceCrop: (Window) -> ...number,
  getChildSurfaces: (Window) -> { ChildSurface },
  close: (Window) -> boolean,
}
export type Monitor = {
  id: string,
  name: string,
  dead: boolean,
  width: number,
  height: number,
  sink: Sink,
  mirrored: boolean?,
  pending: boolean?,
  paused: boolean?,
  frameTransform: string?,
  logicalWidth: number?,
  logicalHeight: number?,
  mirror: (Monitor) -> boolean,
  getTexture: (Monitor) -> Texture?,
  dismiss: (Monitor) -> boolean,
  setPaused: (Monitor, boolean) -> boolean,
}
export type Seat = {
  id: number,
  name: string?,
  dead: boolean,
  focus: Sink?,
  drag: Drag?,
  setFocus: (Seat, Sink?) -> boolean,
  strokeFor: (Seat, string) -> lunette.Stroke?,
  characterFor: (Seat, number, { lunette.ModifierName }?) -> string?,
  symbolFor: (Seat, number, { lunette.ModifierName }?) -> number,
  destroy: (Seat) -> boolean,
}
export type Claim = {
  dead: boolean,
  granted: boolean,
  layer: Layer | false,
  width: number?,
  height: number?,
  release: (Claim) -> boolean,
  setPose: (Claim) -> boolean,
  setSize: (Claim) -> boolean,
}
export type Process = { id: number, argv: { read [number]: string }, dead: boolean }
export type Controller = {
  tracked: boolean,
  origin: vector,
  direction: vector,
  pose: Mat4,
  buttons: { [string]: boolean },
  axisX: number,
  axisY: number,
  trigger: number?,
}
-- Generated sink methods retain even arguments they do not interpret.
export type InputCall = { [number]: unknown, kind: string? }
export type ErrorEvent = { read message: string, read traceback: string }
export type ProcessExitedEvent = {
  read process: ProcessIdentity,
  read outcome: 'exited' | 'signalled' | 'spawnFailed',
  read code: number?,
  read signal: number?,
  read message: string?,
}
export type Event = { read window: Window } | { read monitor: Monitor } | ProcessExitedEvent | ErrorEvent
-- The named registry stores callbacks with different payloads; only storage erases that payload.
type Subscription = { callback: (any) -> (), active: boolean }
export type Events = {
  subscriptions: { [string]: { Subscription } },
  claims: { Claim },
  seats: { Seat },
  windows: { Window },
  monitors: { [number | string]: Monitor },
  outputs: { Output },
  spawned: { Process },
  input: { InputCall },
  draw: { render.Call },
  logs: { { string? } },
  held: { [string]: boolean },
  controllers: { [string]: Controller },
  reported: { { message: string, traceback: string, logged: string } },
  reads: number,
  writes: number,
  enumerations: number,
  closed: number,
  writeMode: 'ok' | 'refuse',
  time: number,
  rates: { { window: number, rate: number? } },
  modes: { { output: number, scale: number? } },
  pauses: { { monitor: string, paused: boolean } },
  textures: number?,
  mirrored: number?,
  unmirrored: number?,
  monitorSelections: number?,
  monitorSelection: lunette.MonitorSelection?,
  dt: number?,
  haptics: number?,
  haptic: { device: string, strength: number, duration: number }?,
  saved: string?,
  render: render.Recorder,
  pass: render.Pass,
}
export type Fake = {
  events: Events,
  emit: <E>(string, E) -> (),
  subscriptionCount: (string) -> number,
  raise: (string, string) -> string,
  newOutput: (number, number?) -> Output,
  newWindow: (number, string?) -> Window,
  newMonitor: (string) -> Monitor,
  assertResourcesReleased: () -> (),
}
type Subscribe = <E>(string, (E) -> ()) -> () -> ()

local installNative: (Fake, Events, Subscribe, () -> ()) -> ()
local installLovr: (Events) -> ()

local SINK_METHODS = { 'key', 'setModifiers', 'pointer', 'motion', 'button', 'scroll', 'enter', 'leave' }
local SUBSCRIPTIONS = { 'onWindowOpened', 'onWindowClosed', 'onProcessExited', 'onMonitorAdded', 'onError' }

function native.new(): Fake
  local fake: Fake = {}
  local events: Events = {
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
    held = {},
    controllers = {},
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

  local function subscribe<E>(name: string, callback: (E) -> ()): () -> ()
    local list = events.subscriptions[name] or {}
    events.subscriptions[name] = list
    local record = { callback = callback, active = true }
    list[#list + 1] = record
    return function()
      assert(record.active, 'subscription disposed twice')
      record.active = false
    end
  end

  function fake.emit<E>(name: string, event: E)
    for _, record in ipairs(table.clone(events.subscriptions[name] or {})) do
      if record.active then
        record.callback(event)
      end
    end
  end

  function fake.subscriptionCount(name: string): number
    local count = 0
    for _, record in ipairs(events.subscriptions[name] or {}) do
      if record.active then
        count += 1
      end
    end
    return count
  end

  function fake.raise(message: string, traceback: string): string
    local listeners: { (ErrorEvent) -> () } = {}
    for _, record in ipairs(events.subscriptions.onError or {}) do
      if record.active then
        listeners[#listeners + 1] = record.callback
      end
    end
    local logged = host.reportTraced(listeners, message, traceback)
    events.reported[#events.reported + 1] = { message = message, traceback = traceback, logged = logged }
    return logged
  end

  -- Reload requires every plugin subscription to end before native subscriptions are cleared.
  local function clearSubscriptions()
    for name in pairs(events.subscriptions) do
      assert(fake.subscriptionCount(name) == 0, 'subscription outlived plugin shutdown: ' .. name)
    end
  end

  function fake.newOutput(id: number, scale: number?): Output
    local output = { id = id, dead = false, width = 1920, height = 1080, scale = scale or 1, refresh = 60 }
    function output.setMode(self: Output, mode: { read scale: number? }): boolean
      events.modes[#events.modes + 1] = { output = self.id, scale = mode.scale }
      if mode.scale then
        self.scale = mode.scale
      end
      return true
    end
    return output
  end
  events.outputs[1] = fake.newOutput(1)

  local function newSink(domain: 'window' | 'host'): Sink
    local sink: Sink = { domain = domain }
    for _, name in ipairs(SINK_METHODS) do
      sink[name] = function(_: Sink, ...: unknown): boolean
        events.input[#events.input + 1] = { name, ... }
        return true
      end
    end
    return sink
  end

  function fake.newWindow(id: number, appId: string?): Window
    local window = {
      id = id,
      appId = appId or 'terminal',
      title = 'Fixture window',
      dead = false,
      width = 1000,
      height = 500,
      properties = {},
      contentType = 'none',
      sourceCrop = { 0, 0, 1, 1 },
      serverSideDecorations = true,
      commit = 0,
      output = events.outputs[1],
      sink = newSink 'window',
    }
    function window.setFrameRate(self: Window, rate: number?): boolean
      events.rates[#events.rates + 1] = { window = self.id, rate = rate }
      self.rate = rate
      return true
    end
    function window.getProperty(self: Window, key: string): unknown
      return self.properties[key]
    end
    function window.setProperty(self: Window, key: string, value: unknown): boolean
      self.properties[key] = value
      return true
    end
    function window.getTexture(self: Window): nil
      events.textures = (events.textures or 0) + 1
      return nil
    end
    function window.getSourceCrop(self: Window): ...number
      return table.unpack(self.sourceCrop)
    end
    function window.getChildSurfaces(self: Window): { ChildSurface }
      return self.children or {}
    end
    function window.close(self: Window): boolean
      events.closed += 1
      self.dead = true
      return true
    end
    return window
  end

  function fake.newMonitor(id: string): Monitor
    local monitor = { id = id, name = id, dead = false, width = 1920, height = 1080, sink = newSink 'host' }
    function monitor.mirror(self: Monitor): boolean
      events.mirrored = (events.mirrored or 0) + 1
      self.mirrored = true
      return true
    end
    function monitor.getTexture(self: Monitor): nil
      return nil
    end
    function monitor.dismiss(self: Monitor): boolean
      events.unmirrored = (events.unmirrored or 0) + 1
      self.mirrored, self.pending = false, false
      return true
    end
    function monitor.setPaused(self: Monitor, paused: boolean): boolean
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
    events.render:assertMeshesReleased()
  end

  installNative(fake, events, subscribe, clearSubscriptions)
  installLovr(events)
  return fake
end

installNative = function(fake: Fake, events: Events, subscribe: Subscribe, clearSubscriptions: () -> ())
  for _, name in ipairs(SUBSCRIPTIONS) do
    lunette[name] = function<E>(callback: (E) -> ()): () -> ()
      return subscribe(name, callback)
    end
  end
  lunette.reportError = function(fields: lunette.ReportErrorOptions)
    fake.raise(fields.context .. ': ' .. fields.message, fields.traceback or '')
  end
  lunette.windows = function(): { Window }
    events.enumerations += 1
    assert(fake.subscriptionCount 'onWindowOpened' > 0, 'subscribe before window enumeration')
    return table.clone(events.windows)
  end
  lunette.monitors = function(): { [number | string]: Monitor }
    return events.monitors
  end
  lunette.selectMonitors = function(): (boolean, string?)
    events.monitorSelections = (events.monitorSelections or 0) + 1
    if #events.monitors == 0 then
      return false, 'monitor selection: no host monitors are attached'
    end
    if events.monitorSelection and events.monitorSelection.state == 'pending' then
      return false, 'monitor selection: a request is already pending'
    end
    events.monitorSelection = { state = 'pending' }
    return true
  end
  lunette.monitorSelection = function(): lunette.MonitorSelection
    return table.clone(events.monitorSelection or { state = 'idle' })
  end
  lunette.outputs = function(): { Output }
    return table.clone(events.outputs)
  end
  lunette.seats = function(): { Seat }
    return events.seats
  end
  lunette.spawn = function(options: lunette.SpawnOptions): Process
    local process = { id = #events.spawned + 1, argv = options.argv, dead = false }
    events.spawned[#events.spawned + 1] = process
    return process
  end
  lunette.newSeat = function(options: lunette.SeatOptions): Seat
    local seat = { id = #events.seats + 1, name = options.name, dead = false }
    events.seats[#events.seats + 1] = seat
    function seat.setFocus(self: Seat, sink: Sink?): boolean
      self.focus = sink
      return true
    end
    function seat.strokeFor(self: Seat, text: string): lunette.Stroke?
      if text == 'q' then
        return { keycode = 16, modifiers = {} }
      elseif text == 'Q' then
        return { keycode = 16, modifiers = { 'shift' } }
      end
      return nil
    end
    function seat.characterFor(self: Seat, code: number, modifiers: { lunette.ModifierName }?): string?
      return if code == 16 then (if table.find(modifiers or {}, 'shift') then 'Q' else 'q') else nil
    end
    function seat.symbolFor(self: Seat, code: number, _modifiers: { lunette.ModifierName }?): number
      return code
    end
    function seat.destroy(self: Seat): boolean
      if self.dead then
        return false
      end
      self.dead = true
      return true
    end
    return seat
  end
  lunette.claimLayer = function(options: lunette.ClaimOptions): Claim
    local claim = { dead = false, granted = false, layer = false, width = options.width, height = options.height }
    events.claims[#events.claims + 1] = claim
    function claim.release(self: Claim): boolean
      if self.dead then
        return false
      end
      self.dead = true
      return true
    end
    function claim.setPose(self: Claim): boolean
      return true
    end
    function claim.setSize(self: Claim): boolean
      return true
    end
    return claim
  end
  lunette.reload = function(): (boolean, string?)
    return host.reload(clearSubscriptions)
  end
end

installLovr = function(events: Events)
  local recorder = render.new(function(): { render.Call }
    return events.draw
  end)
  local font = recorder.font
  events.render = recorder
  lovr.graphics = {
    newMesh = function(count: number): render.Mesh
      return recorder:newMesh(count)
    end,
    newFont = function(file: string, size: number, spread: number): render.Font
      return recorder:newFont(file, size, spread)
    end,
    newShader = function(vertex: string, fragment: string): render.Shader
      return recorder:newShader(vertex, fragment)
    end,
    getDefaultFont = function(): render.Font
      return font
    end,
  }
  lovr.timer = {
    getTime = function(): number
      return events.time
    end,
  }
  lovr.system = {
    isKeyDown = function(key: string): boolean
      return events.held[key] == true
    end,
  }
  -- A hand without controller state is untracked; the head keeps a fixed pose.
  local function controller(device: string?): Controller?
    if device and device:find('left', 1, true) then
      return events.controllers.left
    elseif device and device:find('right', 1, true) then
      return events.controllers.right
    end
    return nil
  end
  lovr.headset = {
    isTracked = function(device: string): boolean
      local state = controller(device)
      if state then
        return state.tracked
      end
      return device == 'head'
    end,
    getPose = function(device: string): (number, number, number, number, number, number, number)
      local state = controller(device)
      if state then
        local x, y, z = state.pose:getPosition()
        local angle, ax, ay, az = state.pose:getOrientation()
        return x, y, z, angle, ax, ay, az
      end
      return 0, 1.5, 0, 0, 0, 1, 0
    end,
    getPosition = function(device: string): (number, number, number)
      local state = controller(device)
      if state then
        return state.origin:unpack()
      end
      return 0, 1.5, 0
    end,
    getDirection = function(device: string): (number, number, number)
      local state = controller(device)
      if state then
        return state.direction:unpack()
      end
      return 0, 0, -1
    end,
    isDown = function(device: string, button: string): boolean
      local state = controller(device)
      return state ~= nil and state.buttons[button] == true
    end,
    getDeltaTime = function(): number
      return events.dt or 0.016
    end,
    getAxis = function(device: string, axis: string): (number, number?)
      local state = controller(device)
      if axis == 'trigger' then
        return if state then state.trigger or (if state.buttons.trigger then 1 else 0) else 0
      end
      if state then
        return state.axisX, state.axisY
      end
      return 0, 0
    end,
    vibrate = function(device: string, strength: number, duration: number): boolean
      events.haptics = (events.haptics or 0) + 1
      events.haptic = { device = device, strength = strength, duration = duration }
      return true
    end,
  }
  lovr.filesystem = {
    read = function(): string?
      events.reads += 1
      return events.saved
    end,
    getSaveDirectory = function(): string
      return '/fixture'
    end,
    write = function(_: string, text: string): boolean
      events.writes += 1
      if events.writeMode == 'refuse' then
        return false
      end
      events.saved = text
      return true
    end,
  }
  lovr.log = function(message: string, level: string?, tag: string?)
    events.logs[#events.logs + 1] = { message, level, tag }
  end
  events.pass = recorder.pass
end

return native
