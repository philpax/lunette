-- Owns pointer button edges, surface capture, and independent native button inverses.
local lunette = require '@lunette'
local contracts = require '@lunette-contracts/interaction'
local vocabulary = require '@lunette-contracts/vocabulary'

local input = {}

type Pointer = contracts.Pointer
type Surface = contracts.Surface
type Button = lunette.PointerButton
type Inverse = () -> ()
export type Capture = {
  surface: Surface,
  onPointer: ((Surface, contracts.PointerEvent) -> ())?,
  onRelease: ((Surface, Pointer) -> ())?,
  x: number?,
  y: number?,
  inside: boolean,
}
export type NativePress = { sink: lunette.Sink, surface: Surface? }

export type State = {
  dead: boolean,
  generation: number,
  withdrawing: boolean,
  seat: lunette.Seat?,
  hovered: Surface?,
  hoveredSink: lunette.Sink?,
  hitX: number?,
  hitY: number?,
  distance: number?,
  held: { [Button]: boolean },
  pressed: { [Button]: boolean },
  blocked: { [Button]: boolean },
  quarantined: boolean,
  captures: { [Button]: Capture },
  pendingCaptures: { [Capture]: { reason: contracts.CancelReason? } },
  pressedSink: { [Button]: NativePress },
}

export type Host = {
  read live: () -> boolean,
  read focus: (lunette.Sink) -> (),
  read hoveredByAnother: (Surface) -> boolean,
}
export type Sample = { held: { [Button]: boolean }, down: { [Button]: boolean } }

local POINTER_DESTROYED: contracts.CancelReason = 'pointer-destroyed'
local SURFACE_DEAD: contracts.CancelReason = 'surface-dead'
local SURFACE_WITHDRAWN: contracts.CancelReason = 'surface-withdrawn'

local function seatLive(state: State): boolean
  return not state.seat or not state.seat.dead
end

local function finite(value: number?, field: string): ()
  if value ~= nil and (type(value) ~= 'number' or value ~= value or math.abs(value) == math.huge) then
    error('interaction: ' .. field .. ' is a finite number', 0)
  end
end

function input.coordinates(x: number?, y: number?, distance: number?): ()
  finite(x, 'surface x')
  finite(y, 'surface y')
  finite(distance, 'surface distance')
end

function input.cancelReason(reason: contracts.CancelReason): ()
  if
    reason ~= 'tracking-loss'
    and reason ~= 'pointer-destroyed'
    and reason ~= 'surface-dead'
    and reason ~= 'surface-withdrawn'
    and reason ~= 'provider-replaced'
    and reason ~= 'hidden'
    and reason ~= 'control-removed'
    and reason ~= 'disabled'
    and reason ~= 'grab'
  then
    error('interaction: cancellation reason is one of the declared reasons, not ' .. tostring(reason), 0)
  end
end

function input.validate(frame: contracts.Input): ()
  local vectors: { [string]: vector } = { origin = frame.origin, direction = frame.direction }
  for name, value in pairs(vectors) do
    if type(value) ~= 'vector' then
      error('interaction: input ' .. name .. ' is a vector', 0)
    end
    finite(value.x, 'input ' .. name .. '.x')
    finite(value.y, 'input ' .. name .. '.y')
    finite(value.z, 'input ' .. name .. '.z')
  end
  finite(frame.scrollX, 'input scrollX')
  finite(frame.scrollY, 'input scrollY')
  finite(frame.dt, 'input dt')
  if frame.dt and frame.dt < 0 then
    error('interaction: input dt is nonnegative', 0)
  end
  if frame.pose then
    local components: { number } = { frame.pose:unpack(true) }
    for index, component in ipairs(components) do
      finite(component, 'input pose[' .. index .. ']')
    end
  end
  if type(frame.grip) ~= 'boolean' or type(frame.buttons) ~= 'table' then
    error('interaction: input has a boolean grip and a button table', 0)
  end
  for button, pressed in frame.buttons do
    if not table.find(vocabulary.POINTER_BUTTONS, button) or type(pressed) ~= 'boolean' then
      error('interaction: input buttons contain only pointer button booleans', 0)
    end
  end
end

local function hasCapture(state: State, surface: Surface): boolean
  for _, capture in pairs(state.captures) do
    if capture.surface == surface then
      return true
    end
  end
  return false
end

local function notify(surface: Surface, event: contracts.PointerEvent): ()
  local callback = surface.onPointer
  if callback then
    callback(surface, table.freeze(event))
  end
end

function input.runInverses(inverses: { Inverse }): ()
  local failures: { string } = {}
  for _, inverse in ipairs(inverses) do
    local ok, failure = pcall(inverse)
    if not ok then
      failures[#failures + 1] = tostring(failure)
    end
  end
  if #failures > 0 then
    error('interaction: pointer cleanup: ' .. table.concat(failures, '; '), 0)
  end
end

local function detachButton(
  state: State,
  pointer: Pointer,
  button: Button,
  reason: contracts.CancelReason?,
  ui: boolean,
  native: boolean
): { Inverse }
  local capture = if ui then state.captures[button] else nil
  local press = if native then state.pressedSink[button] else nil
  if
    not reason
    and (
      (capture and capture.surface.dead)
      or (press and ((press.surface and press.surface.dead) or press.sink.dead or not seatLive(state)))
    )
  then
    reason = SURFACE_DEAD
  end
  if ui then
    state.captures[button] = nil
  end
  if native then
    state.pressedSink[button] = nil
  end
  if not state.captures[button] and not state.pressedSink[button] then
    state.pressed[button] = nil
  end
  if reason and (capture or press) and state.held[button] then
    state.blocked[button] = true
  end
  local inverses: { Inverse } = {}
  if capture then
    local handler, release = capture.onPointer, capture.onRelease
    local pending: { reason: contracts.CancelReason? } = { reason = reason }
    state.pendingCaptures[capture] = pending
    inverses[#inverses + 1] = function()
      if state.pendingCaptures[capture] ~= pending then
        return
      end
      state.pendingCaptures[capture] = nil
      local currentReason: contracts.CancelReason? = pending.reason
      if not currentReason then
        if pointer.dead or state.dead then
          currentReason = POINTER_DESTROYED
        elseif capture.surface.dead or (press and (press.sink.dead or not seatLive(state))) then
          currentReason = SURFACE_DEAD
        end
      end
      if handler then
        if currentReason ~= nil then
          local cancelReason: contracts.CancelReason = currentReason
          local event: contracts.PointerEvent = {
            kind = 'cancel',
            pointer = pointer,
            button = button,
            reason = cancelReason,
            x = capture.x,
            y = capture.y,
            inside = capture.inside,
            captured = true,
          }
          handler(capture.surface, table.freeze(event))
        else
          local event: contracts.PointerEvent = {
            kind = 'release',
            pointer = pointer,
            button = button,
            x = capture.x,
            y = capture.y,
            inside = capture.inside,
            captured = true,
          }
          handler(capture.surface, table.freeze(event))
        end
      elseif release then
        release(capture.surface, pointer)
      end
    end
  end
  if press then
    inverses[#inverses + 1] = function()
      if not press.sink.dead and seatLive(state) then
        press.sink:button(button, false, state.seat)
      end
    end
  end
  return inverses
end

function input.detach(
  state: State,
  pointer: Pointer,
  surface: Surface?,
  reason: contracts.CancelReason,
  releaseNative: boolean?
): { Inverse }
  input.cancelReason(reason)
  state.generation += 1
  for capture, pending in pairs(state.pendingCaptures) do
    if not pending.reason and (surface == nil or capture.surface == surface) then
      pending.reason = reason
    end
  end
  local inverses: { Inverse } = {}
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    local capture, press = state.captures[button], state.pressedSink[button]
    local ui = surface == nil or (capture ~= nil and capture.surface == surface)
    local native = releaseNative ~= false and (surface == nil or (press ~= nil and press.surface == surface))
    if ui or native then
      for _, inverse in ipairs(detachButton(state, pointer, button, reason, ui, native)) do
        inverses[#inverses + 1] = inverse
      end
    end
  end
  return inverses
end

function input.resolve(state: State, pointer: Pointer, surfaces: { read [number]: Surface }): ()
  local offered: { [Surface]: boolean } = {}
  for index = 1, #surfaces do
    offered[surfaces[index]] = true
  end
  local inverses: { Inverse } = {}
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    local capture, press = state.captures[button], state.pressedSink[button]
    local surface = if capture then capture.surface else press and press.surface
    local reason: contracts.CancelReason? = nil
    if surface then
      if surface.dead then
        reason = SURFACE_DEAD
      elseif not offered[surface] then
        reason = SURFACE_WITHDRAWN
      end
    end
    if not reason and press and (press.sink.dead or not seatLive(state)) then
      reason = SURFACE_DEAD
    end
    if reason then
      for _, inverse in ipairs(detachButton(state, pointer, button, reason, true, true)) do
        inverses[#inverses + 1] = inverse
      end
    end
  end
  input.runInverses(inverses)
end

function input.observe(state: State, held: { read [Button]: boolean }): ()
  if not state.quarantined then
    return
  end
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    if held[button] == true then
      return
    end
  end
  state.quarantined = false
end

function input.sample(state: State, held: { read [Button]: boolean }): Sample
  local sample: Sample = { held = {}, down = {} }
  local allUp = true
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    local down = held[button] == true
    if down then
      allUp = false
      sample.held[button] = true
      if not state.held[button] and not state.blocked[button] and not state.quarantined then
        sample.down[button] = true
      end
    else
      state.blocked[button] = nil
    end
    state.held[button] = if down then true else nil
  end
  if state.quarantined and allUp then
    state.quarantined = false
  end
  return sample
end

local function hoverInverses(state: State, pointer: Pointer, previous: Surface, host: Host): { Inverse }
  local x, y = state.hitX, state.hitY
  local captured = hasCapture(state, previous)
  local generation = state.generation
  local withdrawing = state.withdrawing or state.dead
  local sink = state.hoveredSink
  local handler = if sink then nil else previous.onPointer
  local leave = if sink then nil else previous.onLeave
  return {
    function()
      if previous.setHighlighted and not host.hoveredByAnother(previous) then
        previous:setHighlighted(false)
      end
    end,
    function()
      if sink and not sink.dead and seatLive(state) then
        sink:leave(state.seat)
      end
    end,
    function()
      if not withdrawing and (not host.live() or state.generation ~= generation) then
        return
      end
      if handler then
        local event: contracts.PointerEvent = {
          kind = 'leave',
          pointer = pointer,
          x = x,
          y = y,
          inside = false,
          captured = captured,
        }
        handler(previous, table.freeze(event))
      elseif leave then
        leave(previous, pointer)
      end
    end,
  }
end

function input.clearHover(state: State, pointer: Pointer, host: Host): { Inverse }
  local previous = state.hovered
  local inverses = if previous then hoverInverses(state, pointer, previous, host) else {}
  state.hovered, state.hoveredSink, state.hitX, state.hitY, state.distance = nil, nil, nil, nil, nil
  return inverses
end

function input.hover(
  state: State,
  pointer: Pointer,
  hit: Surface?,
  x: number?,
  y: number?,
  distance: number?,
  sink: lunette.Sink?,
  host: Host
): ()
  local previous = state.hovered
  local inverses = if previous and previous ~= hit then hoverInverses(state, pointer, previous, host) else {}
  state.hovered, state.hoveredSink, state.hitX, state.hitY, state.distance = hit, sink, x, y, distance
  if previous == hit then
    return
  end
  local generation = state.generation
  if hit then
    inverses[#inverses + 1] = function()
      if host.live() and state.generation == generation and not hit.dead and hit.setHighlighted then
        hit:setHighlighted(true)
      end
    end
    inverses[#inverses + 1] = function()
      if not sink and host.live() and state.generation == generation and not hit.dead then
        notify(hit, {
          kind = 'enter',
          pointer = pointer,
          x = x,
          y = y,
          inside = true,
          captured = hasCapture(state, hit),
        })
      end
    end
  end
  input.runInverses(inverses)
end

local function press(
  state: State,
  pointer: Pointer,
  button: Button,
  sink: lunette.Sink?,
  surface: Surface?,
  host: Host
): ()
  state.pressed[button] = true
  local generation = state.generation
  if sink then
    if not sink.dead and seatLive(state) then
      state.pressedSink[button] = { sink = sink, surface = surface }
      sink:button(button, true, state.seat)
      if host.live() and state.generation == generation and state.pressedSink[button] then
        host.focus(sink)
      end
    end
  elseif surface and not surface.dead then
    local handler, legacy = surface.onPointer, surface.onPress
    if handler or legacy then
      local capture: Capture = {
        surface = surface,
        onPointer = handler,
        onRelease = if handler then nil else surface.onRelease,
        x = state.hitX,
        y = state.hitY,
        inside = state.hovered == surface,
      }
      state.captures[button] = capture
      if handler then
        local event: contracts.PointerEvent = {
          kind = 'press',
          pointer = pointer,
          button = button,
          x = capture.x,
          y = capture.y,
          inside = capture.inside,
          captured = true,
        }
        handler(surface, table.freeze(event))
      elseif legacy then
        legacy(surface, capture.x, capture.y, pointer)
      end
    end
  end
end

function input.releases(state: State, pointer: Pointer, sample: Sample): { Inverse }
  local releases: { Inverse } = {}
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    if not sample.held[button] then
      for _, inverse in ipairs(detachButton(state, pointer, button, nil, true, true)) do
        releases[#releases + 1] = inverse
      end
    end
  end
  return releases
end

function input.buttons(
  state: State,
  pointer: Pointer,
  sample: Sample,
  sink: lunette.Sink?,
  surface: Surface?,
  host: Host,
  allowPress: boolean?
): ()
  local generation = state.generation
  input.runInverses(input.releases(state, pointer, sample))
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    if not host.live() or state.generation ~= generation then
      return
    end
    if allowPress ~= false and sample.down[button] and not state.blocked[button] and not state.quarantined then
      press(state, pointer, button, sink, surface, host)
    end
  end
end

function input.setButton(state: State, pointer: Pointer, given: contracts.ButtonState, host: Host): ()
  if type(given.pressed) ~= 'boolean' then
    error('interaction: setButton pressed is a boolean', 0)
  end
  local button = given.button or 'left'
  local wasHeld = state.held[button] == true
  state.held[button] = if given.pressed then true else nil
  if not given.pressed then
    state.blocked[button] = nil
    input.runInverses(detachButton(state, pointer, button, nil, true, true))
  elseif not wasHeld and not state.blocked[button] and not state.quarantined then
    press(state, pointer, button, given.sink, given.surface, host)
  end
end

function input.motion(
  state: State,
  pointer: Pointer,
  frame: contracts.Input,
  hit: Surface?,
  sink: lunette.Sink?,
  reach: number,
  host: Host
): ()
  local generation = state.generation
  local captures = table.clone(state.captures)
  local length = frame.direction:length()
  local ray = if length > 0 then frame.direction * (1 / length) else frame.direction
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    local capture = captures[button]
    if capture and not capture.surface.dead then
      local target = capture.surface
      local x, y, distance = target:raycast(frame.origin, ray)
      if not host.live() or state.generation ~= generation then
        return
      end
      input.coordinates(x, y, distance)
      local inside = x ~= nil and y ~= nil and distance ~= nil and distance <= reach
      if target.project then
        x, y, distance = target:project(frame.origin, ray)
      end
      if not host.live() or state.generation ~= generation then
        return
      end
      input.coordinates(x, y, distance)
      if state.captures[button] == capture then
        capture.x, capture.y, capture.inside = x, y, inside
      end
    end
  end
  if hit and not hit.dead then
    if sink then
      if not sink.dead and seatLive(state) and state.hitX and state.hitY then
        sink:pointer(state.hitX, state.hitY, state.seat)
      end
    elseif hit.onPointer then
      notify(hit, {
        kind = 'move',
        pointer = pointer,
        x = state.hitX,
        y = state.hitY,
        inside = true,
        captured = hasCapture(state, hit),
      })
    elseif hit.onHover then
      hit:onHover(state.hitX, state.hitY, pointer)
    end
  end
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    if not host.live() or state.generation ~= generation then
      return
    end
    local capture = captures[button]
    if capture and capture.onPointer and state.captures[button] == capture and not capture.surface.dead then
      local event: contracts.PointerEvent = {
        kind = 'move',
        pointer = pointer,
        button = button,
        x = capture.x,
        y = capture.y,
        inside = capture.inside,
        captured = true,
      }
      capture.onPointer(capture.surface, table.freeze(event))
    end
  end
end

function input.scroll(state: State, pointer: Pointer, hit: Surface?, sink: lunette.Sink?, dx: number, dy: number): ()
  if dx == 0 and dy == 0 then
    return
  end
  if sink then
    if not sink.dead and seatLive(state) then
      sink:scroll(dx, dy, state.seat)
    end
  elseif hit and not hit.dead and hit.onPointer then
    notify(hit, {
      kind = 'scroll',
      pointer = pointer,
      x = state.hitX,
      y = state.hitY,
      inside = true,
      captured = hasCapture(state, hit),
      dx = dx,
      dy = dy,
    })
  end
end

return input
