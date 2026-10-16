-- Routes surface pointer events to nodes: hit testing, hover, press capture, drags, scrolling, and activation.

local uiHost = require '@lunette-contracts/ui-host'
local vocabulary = require '@lunette-contracts/vocabulary'
local records = require './records'
local handles = require './handles'

local input = {}

-- Movement past this distance from the press point turns a press on a dragging node into a drag.
local DRAG_THRESHOLD = 0.003
local PRESS_HAPTIC = table.freeze { strength = 0.25, duration = 0.012 }

type Capture = {
  node: records.Node,
  startX: number,
  startY: number,
  lastX: number,
  lastY: number,
  dragging: boolean,
}

type PointerState = {
  hovered: records.Node?,
  capture: Capture?,
  -- The overlay panel that took this pointer's press from its opener; a release over one of its nodes activates it.
  handoff: records.Panel?,
}

export type Router = {
  pointers: { [vocabulary.Pointer]: PointerState },
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
function input.target(panel: records.Panel, env: records.Environment, x: number, y: number): records.Node?
  local node = input.deepest(panel, x, y)
  while node do
    if interactive(env, node) then
      return node
    end
    node = node.parent
  end
  return nil
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

local function setHovered(env: records.Environment, state: PointerState, node: records.Node?): ()
  local previous = state.hovered
  if previous == node then
    return
  end
  state.hovered = node
  if previous and not previous.dead then
    previous.host.hovers = math.max(previous.host.hovers - 1, 0)
    respond(previous)
    if previous.host.hovers == 0 then
      input.dispatch(env, previous, { kind = 'hover-leave' })
    end
  end
  if node then
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

local function release(env: records.Environment, capture: Capture, x: number, y: number, inside: boolean): ()
  local node = capture.node
  node.host.pressed = false
  node.host.dragging = false
  respond(node)
  if capture.dragging then
    input.dispatch(env, node, { kind = 'drag-end', x = x, y = y }, x, y)
  end
  input.dispatch(env, node, { kind = 'release', x = x, y = y, inside = inside }, x, y)
  if inside and not capture.dragging then
    input.dispatch(env, node, { kind = 'activate' })
  end
end

local function move(env: records.Environment, state: PointerState, x: number, y: number): ()
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
    end
  end
  if capture.dragging then
    local dx, dy = x - capture.lastX, y - capture.lastY
    input.dispatch(env, node, { kind = 'drag', x = x, y = y, dx = dx, dy = dy }, x, y)
  end
  capture.lastX, capture.lastY = x, y
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
  for pointer, state in router.pointers do
    local capture = state.capture
    local movable = (pointer :: any).transfer ~= nil
    if capture and owner and not capture.node.dead and movable and within(capture.node, owner) then
      if pointer:transfer(from, to) then
        local node = capture.node
        state.capture = nil
        state.handoff = target
        node.host.pressed = false
        node.host.dragging = false
        respond(node)
        setHovered(env, state, nil)
      end
    end
  end
end

function input.pointer(
  router: Router,
  panel: records.Panel,
  env: records.Environment,
  event: vocabulary.PointerEvent
): ()
  local state = router.pointers[event.pointer]
  if not state then
    local created: PointerState = { hovered = nil, capture = nil }
    router.pointers[event.pointer] = created
    state = created
  end
  local x, y = event.x, event.y
  if event.kind == 'leave' then
    if not state.capture then
      setHovered(env, state, nil)
    end
    return
  end
  if event.kind == 'cancel' then
    local capture = state.capture
    state.capture = nil
    state.handoff = nil
    if capture and not capture.node.dead then
      capture.node.host.pressed = false
      capture.node.host.dragging = false
      respond(capture.node)
      input.dispatch(env, capture.node, { kind = 'cancel', reason = event.reason })
    end
    setHovered(env, state, nil)
    return
  end
  if x == nil or y == nil then
    -- A captured release can arrive without coordinates when the ray no longer meets the panel's plane. It ends the
    -- capture outside the node, at the last position the capture saw.
    local capture = state.capture
    if event.kind == 'release' and capture and event.button == 'left' then
      state.capture = nil
      if not capture.node.dead then
        release(env, capture, capture.lastX, capture.lastY, false)
      end
      setHovered(env, state, nil)
    end
    return
  end
  local target = input.target(panel, env, x, y)
  if event.kind == 'enter' or event.kind == 'move' then
    move(env, state, x, y)
    if not state.capture then
      setHovered(env, state, target)
    end
  elseif event.kind == 'press' then
    if env.blocked(panel) then
      return
    end
    if event.button == 'left' then
      env.pressed(panel, input.deepest(panel, x, y))
    end
    -- A node takes one capture at a time, so a second pointer cannot press it while it is held.
    if event.button ~= 'left' or state.capture or not target or target.host.pressed then
      return
    end
    state.capture = { node = target, startX = x, startY = y, lastX = x, lastY = y, dragging = false }
    setHovered(env, state, target)
    target.host.pressed = true
    respond(target)
    env.focusNode(target, false)
    if env.haptics() then
      event.pointer:vibrate(PRESS_HAPTIC)
    end
    local source = if (event :: any).touch then 'touch' else 'ray'
    input.dispatch(env, target, { kind = 'press', x = x, y = y, source = source }, x, y)
  elseif event.kind == 'release' then
    local capture = state.capture
    local handed = state.handoff
    if event.button == 'left' and not capture and handed then
      state.handoff = nil
      if handed == panel and target and not target.dead then
        input.dispatch(env, target, { kind = 'activate' })
      end
      return
    end
    if event.button ~= 'left' or not capture then
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
      release(env, capture, x, y, inside)
    end
    setHovered(env, state, target)
  elseif event.kind == 'scroll' then
    local over = input.deepest(panel, x, y)
    if over then
      input.dispatch(env, over, { kind = 'scroll', dx = event.dx, dy = event.dy, x = x, y = y }, x, y)
    end
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

-- Forgets a removed node: a capture on it ends without a release, and hover moves off it.
function input.removed(router: Router, node: records.Node): ()
  for _, state in router.pointers do
    if state.capture and state.capture.node == node then
      state.capture = nil
    end
    if state.hovered == node then
      state.hovered = nil
    end
  end
end

return input
