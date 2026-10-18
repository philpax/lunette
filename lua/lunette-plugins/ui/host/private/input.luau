-- Routes surface pointer events to nodes: hit testing, hover, press capture, drags, scrolling, and activation.

local uiHost = require '@lunette-contracts/ui-host'
local vocabulary = require '@lunette-contracts/vocabulary'
local records = require './records'
local handles = require './handles'

local input = {}

-- Movement past this distance from the press point turns a press on a dragging node into a drag.
local DRAG_THRESHOLD = 0.003
local PRESS_HAPTIC = table.freeze { strength = 0.25, duration = 0.012 }
-- A detent is a lighter, shorter tick than a press, so a sweep across several stays distinct.
local DETENT_HAPTIC = table.freeze { strength = 0.18, duration = 0.006 }

type Capture = {
  node: records.Node,
  startX: number,
  startY: number,
  lastX: number,
  lastY: number,
  dragging: boolean,
}

export type Pointer = { read source: 'ray', read ray: vocabulary.Pointer } | { read source: 'touch' }

export type Event =
  {
    read kind: 'enter' | 'leave' | 'move' | 'press' | 'release',
    read pointer: Pointer,
    read x: number?,
    read y: number?,
    read motion: ('hover' | 'capture')?,
  }
  | {
    read kind: 'scroll',
    read pointer: Pointer,
    read x: number?,
    read y: number?,
    read dx: number,
    read dy: number,
  }
  | {
    read kind: 'cancel',
    read pointer: Pointer,
    read x: number?,
    read y: number?,
    read reason: vocabulary.CancelReason,
  }

type PointerState = {
  pointer: Pointer,
  generation: number,
  hovered: records.Node?,
  capture: Capture?,
  -- The overlay panel that took this pointer's press from its opener; a release over one of its nodes activates it.
  handoff: records.Panel?,
}

export type Router = {
  pointers: { [vocabulary.Pointer | Pointer]: PointerState },
}

function input.new(): Router
  return { pointers = {} }
end

local function contains(node: records.Node, x: number, y: number): boolean
  return x >= node.x and y >= node.y and x <= node.x + node.width and y <= node.y + node.height
end

-- The deepest node under the point, honouring clipping ancestors. Later siblings draw above earlier ones, so they
-- are tested first.
function input.deepest(panel: records.Panel, x: number, y: number): records.Node?
  local function visit(node: records.Node): records.Node?
    local inside = contains(node, x, y)
    if node.kind.registration.clip and not inside then
      return nil
    end
    for index = #node.children, 1, -1 do
      local found = visit(node.children[index])
      if found then
        return found
      end
    end
    return if inside then node else nil
  end
  return if panel.root then visit(panel.root) else nil
end

local function interactive(env: records.Environment, node: records.Node): boolean
  local registration = node.kind.registration
  if registration.interactive then
    local result = false
    env.protect(`ui: {node.kind.name} interactive`, function(): ()
      result = registration.interactive(node.props) == true
    end)
    return result
  end
  return registration.event ~= nil
end

-- The nearest interactive node at or above the deepest node under the point.
function input.target(
  panel: records.Panel,
  env: records.Environment,
  x: number,
  y: number,
  current: (() -> boolean)?
): records.Node?
  local node = input.deepest(panel, x, y)
  while node do
    local accepts = interactive(env, node)
    if panel.dead or node.dead or (current and not current()) then
      return nil
    end
    if accepts then
      return node
    end
    node = node.parent
  end
  return nil
end

-- Whether a trigger press at the point grabs the panel: no hit target lies under it, and the panel is attached to a
-- surface, or the point lies on a handle node such as a header.
function input.grabs(panel: records.Panel, env: records.Environment, x: number, y: number): boolean
  if input.target(panel, env, x, y) then
    return false
  end
  if panel.target then
    return true
  end
  if not panel.grabbable then
    return false
  end
  local node = input.deepest(panel, x, y)
  while node do
    if node.kind.registration.handle then
      return true
    end
    node = node.parent
  end
  return false
end

-- Pulses each pointer whose press the node holds.
function input.pulse(router: Router, node: records.Node, _event: 'detent'): ()
  for _, state in router.pointers do
    local capture = state.capture
    local pointer = state.pointer
    if capture and capture.node == node and pointer.source == 'ray' then
      pointer.ray:vibrate(DETENT_HAPTIC)
    end
  end
end

-- Events carry positions in the receiving node's coordinates. A handler that calls `base` passes the event to the
-- node's parent, except hover changes, which belong to their target alone.
-- Delivers an event, answering whether a handler consumed it. A handler that calls `base` passes the event on, and
-- a node without a handler passes it on too.
function input.dispatch(
  env: records.Environment,
  node: records.Node,
  event: uiHost.Event,
  panelX: number?,
  panelY: number?
): boolean
  if node.dead then
    return false
  end
  local delivered: any = event
  if panelX and panelY and (event :: any).x ~= nil then
    delivered = table.clone(event :: any)
    delivered.x, delivered.y = panelX - node.x, panelY - node.y
  end
  local passed = false
  local consumed = false
  local function base(_handle: uiHost.Node, forwarded: uiHost.Event): ()
    passed = true
    if forwarded.kind == 'hover-enter' or forwarded.kind == 'hover-leave' then
      return
    end
    local parent = node.parent
    if parent then
      consumed = input.dispatch(env, parent, forwarded, panelX, panelY)
    end
  end
  local handler = node.kind.registration.event
  if handler == nil then
    base(node.handle, delivered)
    return consumed
  end
  local ok = env.protect(`ui: {node.kind.name} event {event.kind}`, function(): ()
    handler(node.handle, delivered, base)
  end)
  return ok and (consumed or not passed)
end

local function respond(node: records.Node): ()
  local response = node.kind.registration.response
  local tokens = node.handle.theme.elevation
  local target = 0
  if response and response.travel and node.host.pressed then
    target = math.max(-tokens.pressTravel, tokens.minimumSeparation - node.elevation)
  elseif response and response.lift and node.host.hovers > 0 then
    target = tokens.hoverLift
  end
  node.liftTarget = target
  handles.hostChanged(node)
end

local function key(pointer: Pointer): vocabulary.Pointer | Pointer
  return if pointer.source == 'ray' then pointer.ray else pointer
end

-- A callback can route newer input through the same record, or remove it and create another one.
local function currentState(router: Router, state: PointerState): () -> boolean
  local generation = state.generation
  local identity = key(state.pointer)
  return function(): boolean
    return router.pointers[identity] == state and state.generation == generation
  end
end

local function setHovered(
  env: records.Environment,
  state: PointerState,
  node: records.Node?,
  current: () -> boolean
): ()
  if not current() then
    return
  end
  local previous = state.hovered
  if previous == node then
    return
  end
  state.hovered = nil
  if previous and not previous.dead then
    previous.host.hovers = math.max(previous.host.hovers - 1, 0)
    respond(previous)
    if previous.host.hovers == 0 then
      input.dispatch(env, previous, { kind = 'hover-leave' })
    end
  end
  if not current() then
    return
  end
  if node and not node.dead then
    state.hovered = node
    node.host.hovers += 1
    respond(node)
    if node.host.hovers == 1 then
      input.dispatch(env, node, { kind = 'hover-enter' })
    end
  end
end

-- Whether a node is the ancestor or the node itself.
local function within(node: records.Node, ancestor: records.Node): boolean
  local current: records.Node? = node
  while current do
    if current == ancestor then
      return true
    end
    current = current.parent
  end
  return false
end

local function release(
  env: records.Environment,
  capture: Capture,
  x: number,
  y: number,
  inside: boolean,
  current: () -> boolean
): ()
  local node = capture.node
  node.host.pressed = false
  node.host.dragging = false
  respond(node)
  if capture.dragging then
    input.dispatch(env, node, { kind = 'drag-end', x = x, y = y }, x, y)
    if not current() then
      return
    end
  end
  input.dispatch(env, node, { kind = 'release', x = x, y = y, inside = inside }, x, y)
  if current() and inside and not capture.dragging then
    input.dispatch(env, node, { kind = 'activate' })
  end
end

local function move(env: records.Environment, state: PointerState, x: number, y: number, current: () -> boolean): ()
  local capture = state.capture
  if not capture then
    return
  end
  local node = capture.node
  local claims = node.kind.registration.claims
  if not capture.dragging and claims and claims.drag then
    local dx, dy = x - capture.startX, y - capture.startY
    local distance = if claims.drag == 'x'
      then math.abs(dx)
      elseif claims.drag == 'y' then math.abs(dy)
      else math.sqrt(dx * dx + dy * dy)
    if distance >= DRAG_THRESHOLD then
      capture.dragging = true
      node.host.dragging = true
      handles.refreshState(node, node.handle)
      input.dispatch(
        env,
        node,
        { kind = 'drag-start', x = capture.startX, y = capture.startY },
        capture.startX,
        capture.startY
      )
      if not current() or state.capture ~= capture or node.dead then
        return
      end
    end
  end
  if capture.dragging then
    local dx, dy = x - capture.lastX, y - capture.lastY
    input.dispatch(env, node, { kind = 'drag', x = x, y = y, dx = dx, dy = dy }, x, y)
  end
  if current() and state.capture == capture then
    capture.lastX, capture.lastY = x, y
  end
end

-- Moves the ray presses held inside a portal's owner onto its new overlay. Fingertip pointers cannot transfer, so a
-- touch press stays on the opener.
function input.handoff(
  router: Router,
  env: records.Environment,
  portal: records.Node,
  target: records.Panel,
  from: vocabulary.Surface,
  to: vocabulary.Surface
): ()
  local owner = portal.parent
  for _, state in router.pointers do
    local capture = state.capture
    local pointer = state.pointer
    if capture and owner and not capture.node.dead and pointer.source == 'ray' and within(capture.node, owner) then
      local current = currentState(router, state)
      if pointer.ray:transfer(from, to) and current() and state.capture == capture then
        state.generation += 1
        local node = capture.node
        state.capture = nil
        state.handoff = target
        node.host.pressed = false
        node.host.dragging = false
        respond(node)
        setHovered(env, state, nil, currentState(router, state))
      end
    end
  end
end

local function prune(router: Router, pointer: Pointer, state: PointerState): ()
  local identity = key(pointer)
  if router.pointers[identity] == state and not state.hovered and not state.capture and not state.handoff then
    router.pointers[identity] = nil
  end
end

local function route(
  router: Router,
  panel: records.Panel,
  env: records.Environment,
  event: Event,
  state: PointerState
): ()
  local current = currentState(router, state)
  local x, y = event.x, event.y
  assert(x == nil or (x == x and math.abs(x) < math.huge), 'ui: pointer x is finite')
  assert(y == nil or (y == y and math.abs(y) < math.huge), 'ui: pointer y is finite')
  if event.kind == 'leave' then
    if not state.capture then
      setHovered(env, state, nil, current)
    end
    return
  end
  if event.kind == 'cancel' then
    local capture = state.capture
    local handed = state.handoff
    state.capture = nil
    state.handoff = nil
    if capture and not capture.node.dead then
      capture.node.host.pressed = false
      capture.node.host.dragging = false
      respond(capture.node)
    end
    -- A press-drag-release menu depends on the press, so losing it, as on tracking loss, closes the menu.
    local relation = handed and handed.overlay
    if handed and relation and not handed.dead and not handed.closing then
      relation.portal.handle:emit 'onDismiss'
    end
    if not current() then
      return
    end
    if capture and not capture.node.dead then
      input.dispatch(env, capture.node, { kind = 'cancel', reason = event.reason })
    end
    setHovered(env, state, nil, current)
    return
  end
  if x == nil or y == nil then
    -- A captured release can arrive without coordinates when the ray no longer meets the panel's plane. It ends the
    -- capture outside the node, at the last position the capture saw.
    local capture = state.capture
    if event.kind == 'release' then
      -- A handed-off press released off the overlay's plane chooses nothing.
      state.handoff = nil
    end
    if event.kind == 'release' and capture then
      state.capture = nil
      if not capture.node.dead then
        release(env, capture, capture.lastX, capture.lastY, false, current)
      end
      setHovered(env, state, nil, current)
    end
    return
  end
  local target = if event.kind == 'release' and state.capture then nil else input.target(panel, env, x, y, current)
  if not current() or panel.dead then
    return
  end
  if event.kind == 'enter' or event.kind == 'move' then
    if event.motion == 'capture' and state.capture and state.capture.node.panel == panel then
      move(env, state, x, y, current)
    end
    -- While a press is handed off, only the overlay that holds it sets hover, so the opener under the ray does not
    -- flicker between hovered and not.
    local handed = state.handoff
    if not state.capture and (handed == nil or handed == panel) then
      setHovered(env, state, target, current)
    end
  elseif event.kind == 'press' then
    -- A new press supersedes any handoff left from an earlier one.
    state.handoff = nil
    if env.blocked(panel) or not current() then
      return
    end
    env.pressed(panel, input.deepest(panel, x, y))
    -- A node takes one capture at a time, so a second pointer cannot press it while it is held.
    if not current() or panel.dead or state.capture or not target or target.dead or target.host.pressed then
      return
    end
    local capture: Capture = { node = target, startX = x, startY = y, lastX = x, lastY = y, dragging = false }
    state.capture = capture
    setHovered(env, state, target, current)
    if not current() or state.capture ~= capture or target.dead then
      return
    end
    target.host.pressed = true
    respond(target)
    env.focusNode(target, false)
    if not current() or state.capture ~= capture or target.dead then
      return
    end
    local haptics = env.haptics()
    if not current() then
      return
    end
    if haptics and event.pointer.source == 'ray' then
      event.pointer.ray:vibrate(PRESS_HAPTIC)
    end
    if current() and not target.dead and state.capture == capture then
      input.dispatch(env, target, { kind = 'press', x = x, y = y, source = event.pointer.source }, x, y)
    end
  elseif event.kind == 'release' then
    local capture = state.capture
    local handed = state.handoff
    if not capture and handed then
      state.handoff = nil
      if handed == panel and target and not target.dead then
        input.dispatch(env, target, { kind = 'activate' })
      end
      return
    end
    if not capture then
      return
    end
    state.capture = nil
    if not capture.node.dead then
      local inside = false
      local over = input.deepest(panel, x, y)
      while over do
        if over == capture.node then
          inside = true
          break
        end
        over = over.parent
      end
      release(env, capture, x, y, inside, current)
    end
    if current() and not panel.dead then
      setHovered(env, state, input.target(panel, env, x, y, current), current)
    end
  elseif event.kind == 'scroll' then
    local over = input.deepest(panel, x, y)
    if over then
      input.dispatch(env, over, { kind = 'scroll', dx = event.dx, dy = event.dy, x = x, y = y }, x, y)
    end
  end
end

function input.pointer(router: Router, panel: records.Panel, env: records.Environment, event: Event): ()
  local identity = key(event.pointer)
  local state = router.pointers[identity]
  if not state then
    if event.kind == 'leave' or event.kind == 'cancel' or event.kind == 'release' then
      return
    end
    local created: PointerState = { pointer = event.pointer, generation = 0, hovered = nil, capture = nil }
    router.pointers[identity] = created
    state = created
  end
  state.generation += 1
  route(router, panel, env, event, state)
  prune(router, event.pointer, state)
end

function input.surface(
  router: Router,
  panel: records.Panel,
  env: records.Environment,
  event: vocabulary.PointerEvent
): ()
  local pointer: Pointer = { source = 'ray', ray = event.pointer }
  if event.kind == 'move' then
    if event.button == nil or event.button == 'left' then
      input.pointer(router, panel, env, {
        kind = 'move',
        pointer = pointer,
        x = event.x,
        y = event.y,
        motion = if event.button == 'left' then 'capture' else 'hover',
      })
    end
  elseif event.kind == 'press' then
    if event.button == 'left' then
      input.pointer(router, panel, env, { kind = 'press', pointer = pointer, x = event.x, y = event.y })
    end
  elseif event.kind == 'release' then
    if event.button == 'left' then
      input.pointer(router, panel, env, { kind = 'release', pointer = pointer, x = event.x, y = event.y })
    end
  elseif event.kind == 'cancel' then
    if event.button == 'left' then
      input.pointer(router, panel, env, { kind = 'cancel', pointer = pointer, reason = event.reason })
    end
  elseif event.kind == 'scroll' then
    input.pointer(
      router,
      panel,
      env,
      { kind = 'scroll', pointer = pointer, x = event.x, y = event.y, dx = event.dx, dy = event.dy }
    )
  else
    input.pointer(router, panel, env, { kind = event.kind, pointer = pointer, x = event.x, y = event.y })
  end
end

-- Whether any pointer hovers or holds a node of a host panel.
function input.pointing(router: Router): boolean
  for _, state in router.pointers do
    if state.hovered or state.capture then
      return true
    end
  end
  return false
end

-- Moves what pointers hold on a node to the node that replaces it under a changed registration: a capture in
-- progress, with its press point and drag, and hover. The new node continues the gesture, and its release or drag ends
-- it, so an override that loads mid-drag does not drop the drag.
function input.carried(router: Router, from: records.Node, to: records.Node): ()
  local moved = false
  for _, state in router.pointers do
    local capture = state.capture
    if (capture and capture.node == from) or state.hovered == from then
      state.generation += 1
      moved = true
    end
    if capture and capture.node == from then
      capture.node = to
    end
    if state.hovered == from then
      state.hovered = to
    end
  end
  if not moved then
    return
  end
  to.host.hovers = from.host.hovers
  to.host.pressed = from.host.pressed
  to.host.dragging = from.host.dragging
  from.host.hovers, from.host.pressed, from.host.dragging = 0, false, false
  respond(to)
  handles.refreshState(to, to.handle)
end

-- Forgets a removed node: a capture on it ends without a release, and hover moves off it.
function input.removed(router: Router, node: records.Node): ()
  for _, state in router.pointers do
    if (state.capture and state.capture.node == node) or state.hovered == node then
      state.generation += 1
    end
    if state.capture and state.capture.node == node then
      state.capture = nil
    end
    if state.hovered == node then
      state.hovered = nil
    end
    prune(router, state.pointer, state)
  end
end

return input
