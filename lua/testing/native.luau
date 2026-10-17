-- Provides fake native APIs for tests. The plugin runtime, key and scale vocabularies, and `lovr.math` remain real.
-- setAudioState and pushAudio queue source publications; advanceFrame publishes them without running lovr.update.
-- Audio handle, stream, snapshot, and sample-copy counts are recorded on events.

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
  process: Process?,
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
export type AudioSource = { read kind: 'system' } | { read kind: 'process', read process: Process }
export type AudioState =
  { read kind: 'starting' | 'idle' | 'ended' }
  | { read kind: 'active', read provenance: ('pipewire-client' | 'application-metadata')? }
  | {
    read kind: 'unavailable',
    read reason: 'no-server'
      | 'no-default-sink'
      | 'invalid-default-sink'
      | 'permission-denied'
      | 'unsupported-format'
      | 'unresolved-attribution'
      | 'capacity-exceeded'
      | 'graph-failure',
    read detail: string,
  }
export type AudioBlock = {
  read generation: number,
  read sequence: number,
  read frameCount: number,
  read sampleRate: number,
  read channels: number,
  read startFrame: number,
  read gap: boolean,
  read droppedFrames: number,
  read timing: 'sample-frames',
  read copySamples: (AudioBlock) -> buffer,
}
export type AudioSnapshot = {
  read source: AudioSource,
  read state: AudioState,
  read frameGeneration: number,
  read blocks: { read [number]: AudioBlock },
}
export type AudioHandle = {
  read id: number,
  read dead: boolean,
  read snapshot: (AudioHandle) -> AudioSnapshot,
  read close: (AudioHandle) -> boolean,
}
export type AudioBlockOptions = {
  read generation: number?,
  read sequence: number?,
  read startFrame: number?,
  read gap: boolean?,
  read droppedFrames: number?,
}
type AudioStream = {
  source: AudioSource,
  state: AudioState,
  pendingState: AudioState?,
  readers: number,
  generation: number,
  sequence: number,
  startFrame: number,
  pending: { AudioBlock },
  publication: AudioSnapshot,
}
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
  processes: { Process },
  processEnumerations: number,
  audio: { AudioHandle },
  audioOpened: number,
  audioClosed: number,
  audioSnapshots: number,
  audioCopies: number,
  audioStreamsOpened: number,
  audioStreamsClosed: number,
  frameGeneration: number,
  headTracked: boolean,
  -- False runs the desktop simulator: the headset has no session, and the window shows the head's view.
  headsetActive: boolean,
  -- The simulator window's size, cursor mode, and the view's half-angles in radians.
  window: { width: number, height: number, mouseMode: string, view: { number } },
  eyeTracked: boolean,
  eyeTracking: boolean,
  headPose: Mat4,
  eyePose: Mat4,
  mainSessionVisible: boolean,
  input: { InputCall },
  draw: { render.Call },
  logs: { { string? } },
  held: { [string]: boolean },
  controllers: { [string]: Controller },
  reported: { { message: string, traceback: string, logged: string } },
  reads: number,
  writes: number,
  -- Save files other than the arrangement, by path.
  files: { [string]: string },
  -- Set to a message to make the next `lunette.saveFile` raise it.
  saveFailure: string?,
  enumerations: number,
  closed: number,
  writeMode: 'ok' | 'refuse',
  -- How many times the session asked to restart into safe mode.
  safeModeRestarts: number,
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
  newWindow: (number, string?, Process?) -> Window,
  newMonitor: (string) -> Monitor,
  newProcess: (number, { string }?) -> Process,
  setAudioState: (AudioSource, AudioState) -> (),
  pushAudio: (AudioSource, { number } | buffer, AudioBlockOptions?) -> AudioBlock,
  advanceFrame: (number?) -> (),
  assertResourcesReleased: () -> (),
}
type Subscribe = <E>(string, (E) -> ()) -> () -> ()

local installNative: (Fake, Events, Subscribe, () -> ()) -> ()
local installLovr: (Events) -> ()
local installAudio: (Fake, Events) -> ()

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
    processes = {},
    processEnumerations = 0,
    audio = {},
    audioOpened = 0,
    audioClosed = 0,
    audioSnapshots = 0,
    audioCopies = 0,
    audioStreamsOpened = 0,
    audioStreamsClosed = 0,
    frameGeneration = 0,
    headTracked = true,
    headsetActive = true,
    window = { width = 800, height = 600, mouseMode = 'normal', view = { 0.8, 0.8, 0.65, 0.65 } },
    eyeTracked = false,
    eyeTracking = false,
    headPose = lovr.math.newMat4():translate(0, 1.5, 0),
    eyePose = lovr.math.newMat4():translate(0, 1.5, 0),
    mainSessionVisible = false,
    input = {},
    draw = {},
    logs = {},
    held = {},
    controllers = {},
    reported = {},
    reads = 0,
    writes = 0,
    files = {},
    enumerations = 0,
    closed = 0,
    writeMode = 'ok',
    safeModeRestarts = 0,
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

  function fake.newProcess(id: number, argv: { string }?): Process
    for _, process in events.processes do
      assert(process.id ~= id, 'native fake: process id already registered')
    end
    local process = { id = id, argv = table.freeze(table.clone(argv or {})), dead = false }
    events.processes[#events.processes + 1] = process
    return process
  end

  function fake.newWindow(id: number, appId: string?, process: Process?): Window
    local window = {
      process = process,
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
    for _, handle in events.audio do
      assert(handle.dead, 'leaked native audio handle')
    end
    for name in pairs(events.subscriptions) do
      assert(fake.subscriptionCount(name) == 0, 'leaked subscription: ' .. name)
    end
    assert(events.closed == 0, 'cleanup closed caller-owned window')
    events.render:assertResourcesReleased()
  end

  installNative(fake, events, subscribe, clearSubscriptions)
  installAudio(fake, events)
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
  -- An atomic save into the fake save directory lands where `lovr.filesystem.read` finds it. `events.saveFailure`
  -- makes the next save raise, as a full disk does.
  lunette.saveFile = function(directory: string, name: string, contents: string): ()
    assert(directory == '/fixture', 'saveFile: the fake saves only into the fake save directory')
    assert(not string.find(name, '[/\\%z]') and name ~= '' and name ~= '.' and name ~= '..', 'saveFile: a file name')
    local failure = events.saveFailure
    if failure then
      events.saveFailure = nil
      error(failure, 0)
    end
    events.files[name] = contents
  end
  lunette.windows = function(): { Window }
    events.enumerations += 1
    -- Initial enumeration follows subscription; later frame-snapshot polling need not retain a window cache.
    if events.frameGeneration == 0 then
      assert(fake.subscriptionCount 'onWindowOpened' > 0, 'subscribe before window enumeration')
    end
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
  lunette.processes = function(): { Process }
    events.processEnumerations += 1
    local result = table.clone(events.processes)
    for _, process in events.spawned do
      if not table.find(result, process) then
        result[#result + 1] = process
      end
    end
    return result
  end
  lunette.spawn = function(options: lunette.SpawnOptions): Process
    local id = #events.spawned + 1
    for _, process in events.processes do
      id = math.max(id, process.id + 1)
    end
    local process = fake.newProcess(id, options.argv)
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
  -- Records the request; a test session has no restart to queue.
  lunette.restartIntoSafeMode = function(): (boolean, string?)
    events.safeModeRestarts += 1
    return true, nil
  end
end

-- Injection changes become visible together at advanceFrame, like native frame publication.
installAudio = function(fake: Fake, events: Events)
  local streams: { [string | Process]: AudioStream } = {}
  local function sourceKey(source: AudioSource): string | Process
    assert(type(source) == 'table', 'native fake: audio source must be a descriptor')
    for field in source do
      assert(
        field == 'kind' or (source.kind == 'process' and field == 'process'),
        'native fake: unknown audio source field'
      )
    end
    if source.kind == 'system' then
      assert(source.process == nil, 'native fake: system audio has no process')
      return 'system'
    end
    assert(source.kind == 'process' and type(source.process) == 'table', 'native fake: invalid audio source')
    assert(
      table.find(events.processes, source.process) or table.find(events.spawned, source.process),
      'native fake: unregistered audio process'
    )
    return source.process
  end
  local function publication(source: AudioSource, state: AudioState, blocks: { AudioBlock }): AudioSnapshot
    return table.freeze {
      source = source,
      state = state,
      frameGeneration = events.frameGeneration,
      blocks = table.freeze(blocks),
    }
  end
  local function streamFor(source: AudioSource): AudioStream
    local key = sourceKey(source)
    if not streams[key] then
      local descriptor = table.freeze(table.clone(source))
      local starting = table.freeze { kind = 'starting' }
      streams[key] = {
        source = descriptor,
        state = starting,
        readers = 0,
        generation = 1,
        sequence = 0,
        startFrame = 0,
        pending = {},
        publication = publication(descriptor, starting, {}),
      }
    end
    return streams[key]
  end
  local function immutableState(state: AudioState): AudioState
    assert(
      table.find({ 'starting', 'active', 'idle', 'unavailable', 'ended' }, state.kind),
      'native fake: invalid audio state'
    )
    if state.kind == 'active' then
      assert(
        state.provenance == nil or state.provenance == 'pipewire-client' or state.provenance == 'application-metadata',
        'native fake: invalid audio provenance'
      )
    elseif state.kind == 'unavailable' then
      assert(
        table.find({
          'no-server',
          'no-default-sink',
          'invalid-default-sink',
          'permission-denied',
          'unsupported-format',
          'unresolved-attribution',
          'capacity-exceeded',
          'graph-failure',
        }, state.reason),
        'native fake: invalid audio unavailable reason'
      )
      assert(type(state.detail) == 'string', 'native fake: audio unavailable requires detail')
    end
    return table.freeze(table.clone(state))
  end
  function fake.setAudioState(source: AudioSource, state: AudioState)
    streamFor(source).pendingState = immutableState(state)
  end
  function fake.pushAudio(source: AudioSource, samples: { number } | buffer, options: AudioBlockOptions?): AudioBlock
    local stream = streamFor(source)
    options = options or {}
    local pcm: buffer
    if typeof(samples) == 'buffer' then
      assert(buffer.len(samples) % 8 == 0, 'native fake: audio buffer must contain complete stereo F32 frames')
      pcm = buffer.create(buffer.len(samples))
      buffer.copy(pcm, 0, samples)
    else
      assert(#samples % 2 == 0, 'native fake: audio samples must contain complete stereo frames')
      pcm = buffer.create(#samples * 4)
      for index, value in samples do
        assert(
          type(value) == 'number' and value == value and math.abs(value) < math.huge,
          'native fake: invalid audio sample'
        )
        buffer.writef32(pcm, (index - 1) * 4, value)
      end
    end
    local generation = options.generation or stream.generation
    if generation ~= stream.generation then
      stream.generation, stream.sequence, stream.startFrame = generation, 0, 0
      stream.pending = {}
    end
    local block = {
      generation = generation,
      sequence = options.sequence or stream.sequence,
      frameCount = buffer.len(pcm) / 8,
      sampleRate = 48000,
      channels = 2,
      startFrame = options.startFrame or stream.startFrame,
      gap = options.gap == true or (options.droppedFrames or 0) > 0,
      droppedFrames = options.droppedFrames or 0,
      timing = 'sample-frames',
    }
    for _, field in { 'generation', 'sequence', 'startFrame', 'droppedFrames' } do
      local value = block[field]
      assert(
        type(value) == 'number' and value >= 0 and value < math.huge and value % 1 == 0,
        'native fake: invalid audio ' .. field
      )
    end
    function block.copySamples(_: AudioBlock): buffer
      events.audioCopies += 1
      local copy = buffer.create(buffer.len(pcm))
      buffer.copy(copy, 0, pcm)
      return copy
    end
    table.freeze(block)
    stream.sequence, stream.startFrame = block.sequence + 1, block.startFrame + block.frameCount
    stream.pending[#stream.pending + 1] = block
    return block
  end
  function fake.advanceFrame(dt: number?)
    if dt ~= nil then
      assert(dt >= 0 and dt < math.huge, 'native fake: invalid frame duration')
      events.dt, events.time = dt, events.time + dt
    end
    events.frameGeneration += 1
    for _, stream in streams do
      stream.state = stream.pendingState or stream.state
      stream.pendingState = nil
      if stream.source.kind == 'process' and stream.source.process.dead then
        stream.state = table.freeze { kind = 'ended' }
      end
      local blocks = if stream.state.kind == 'active' then stream.pending else {}
      stream.pending = {}
      stream.publication = publication(stream.source, stream.state, blocks)
    end
  end
  lunette.openAudio = function(source: AudioSource): AudioHandle
    local stream = streamFor(source)
    local capacity = 0
    for _, entry in streams do
      if entry.readers > 0 then
        capacity += 1
      end
    end
    local denied = stream.readers == 0 and capacity >= 8
    local handle = { id = #events.audio + 1, dead = false }
    events.audio[#events.audio + 1] = handle
    events.audioOpened += 1
    if not denied then
      if stream.readers == 0 then
        events.audioStreamsOpened += 1
      end
      stream.readers += 1
    end
    function handle.snapshot(self: AudioHandle): AudioSnapshot
      events.audioSnapshots += 1
      if self.dead or (stream.source.kind == 'process' and stream.source.process.dead) then
        return publication(stream.source, table.freeze { kind = 'ended' }, {})
      elseif denied then
        return publication(
          stream.source,
          table.freeze {
            kind = 'unavailable',
            reason = 'capacity-exceeded',
            detail = 'native fake: audio source capacity exceeded',
          },
          {}
        )
      end
      return stream.publication
    end
    function handle.close(self: AudioHandle): boolean
      if self.dead then
        return false
      end
      handle.dead = true
      events.audioClosed += 1
      if not denied then
        stream.readers -= 1
        if stream.readers == 0 then
          events.audioStreamsClosed += 1
          streams[sourceKey(stream.source)] = nil
        end
      end
      return true
    end
    return handle
  end
end

installLovr = function(events: Events)
  local recorder = render.new(function(): { render.Call }
    return events.draw
  end)
  local font = recorder.font
  events.render = recorder
  lovr.graphics = {
    newMesh = function(...: any): render.Mesh
      return recorder:newMesh(...)
    end,
    newFont = function(file: string, size: number, spread: number): render.Font
      return recorder:newFont(file, size, spread)
    end,
    newShader = function(vertex: string, fragment: string): render.Shader
      return recorder:newShader(vertex, fragment)
    end,
    newTexture = function(source: any, options: any?): render.Texture
      return recorder:newTexture(source, options)
    end,
    getDefaultFont = function(): render.Font
      return font
    end,
  }
  -- A blob carries its contents to a constructor such as `newFont`, which the fake does not parse.
  lovr.data = {
    newBlob = function(contents: string, name: string?): { read contents: string, read name: string? }
      return table.freeze { contents = contents, name = name }
    end,
    newImage = function(width: number, height: number, format: string, blob: any): any
      return table.freeze { width = width, height = height, format = format, blob = blob }
    end,
  } :: any
  lovr.timer = {
    getTime = function(): number
      return events.time
    end,
  }
  lovr.system = {
    isKeyDown = function(...: string): boolean
      for _, key in { ... } do
        if events.held[key] == true then
          return true
        end
      end
      return false
    end,
    getWindowDimensions = function(): (number, number)
      return events.window.width, events.window.height
    end,
    getMouseMode = function(): string
      return events.window.mouseMode
    end,
    setMouseMode = function(mode: string): ()
      events.window.mouseMode = mode
    end,
  }
  -- Hands, head, and gaze have independent tracking so a missing gaze never moves the head.
  local function controller(device: string?): Controller?
    if device and device:find('left', 1, true) then
      return events.controllers.left
    elseif device and device:find('right', 1, true) then
      return events.controllers.right
    end
    return nil
  end
  local function pose(device: string?): Mat4
    if device == 'eye/gaze' then
      return events.eyePose
    end
    return events.headPose
  end
  lovr.headset = {
    getFeatures = function(): { read eyeTracking: boolean }
      return { eyeTracking = events.eyeTracking }
    end,
    isMainSessionVisible = function(): boolean
      return events.mainSessionVisible
    end,
    isActive = function(): boolean
      return events.headsetActive
    end,
    getViewAngles = function(_view: number): (number, number, number, number)
      local view = events.window.view
      return view[1], view[2], view[3], view[4]
    end,
    setPose = function(
      device: string,
      x: number,
      y: number,
      z: number,
      angle: number,
      ax: number,
      ay: number,
      az: number
    )
      if device == 'head' then
        events.headPose:set(lovr.math.newMat4():translate(x, y, z):rotate(angle, ax, ay, az))
      end
    end,
    isTracked = function(device: string): boolean
      local state = controller(device)
      if state then
        return state.tracked
      elseif device == 'head' then
        return events.headTracked
      elseif device == 'eye/gaze' then
        return events.eyeTracking and events.eyeTracked
      end
      return false
    end,
    getPose = function(device: string): (number, number, number, number, number, number, number)
      local state = controller(device)
      if state then
        local x, y, z = state.pose:getPosition()
        local angle, ax, ay, az = state.pose:getOrientation()
        return x, y, z, angle, ax, ay, az
      end
      local x, y, z = pose(device):getPosition()
      local angle, ax, ay, az = pose(device):getOrientation()
      return x, y, z, angle, ax, ay, az
    end,
    getPosition = function(device: string): (number, number, number)
      local state = controller(device)
      if state then
        return state.origin:unpack()
      end
      return pose(device):getPosition()
    end,
    getDirection = function(device: string): (number, number, number)
      local state = controller(device)
      if state then
        return state.direction:unpack()
      end
      return vector.pack(pose(device):mul(0, 0, -1, 0)):normalize():unpack()
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
    -- Alias paths name files in the mounted module roots, as LÖVR's filesystem serves them. A `.state` file is the
    -- arrangement stream that tests count and replace; other save files, such as accessibility settings, are kept
    -- per path in `events.files`.
    read = function(path: string?): string?
      if type(path) == 'string' and string.sub(path, 1, 1) == '@' then
        return host.readFile(path)
      end
      if type(path) == 'string' and string.sub(path, -6) ~= '.state' then
        return events.files[path]
      end
      events.reads += 1
      return events.saved
    end,
    getSaveDirectory = function(): string
      return '/fixture'
    end,
    write = function(path: string, text: string): boolean
      if string.sub(path, -6) ~= '.state' then
        events.files[path] = text
        return true
      end
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
