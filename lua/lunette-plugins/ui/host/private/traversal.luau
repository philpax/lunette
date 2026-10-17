-- Session focus and traversal for host panels: each panel that needs keyboard input registers a local target with
-- the focus service, keys reach the focused node or drive traversal, and a controller's thumbstick and face buttons
-- traverse the panel that holds session focus while no ray points at a host panel.

local plugin = require '@lunette-plugin'
local focusContract = require '@lunette-contracts/focus'
local keys = require '@lunette-contracts/keys'
local records = require './records'
local focus = require './focus'

local traversal = {}

-- Thumbstick deflection that counts as a direction, and the deflection it must fall below before it counts again.
local STICK_PRESS = 0.6
local STICK_RELEASE = 0.3

export type Traversal = {
  context: plugin.Context,
  service: focusContract.Service,
  env: records.Environment,
  panels: () -> { records.Panel },
  -- Edge state of the controller inputs, per hand.
  stick: { [string]: string? },
  buttons: { [string]: { [string]: boolean } },
}

function traversal.new(
  context: plugin.Context,
  service: focusContract.Service,
  env: records.Environment,
  panels: () -> { records.Panel }
): Traversal
  return { context = context, service = service, env = env, panels = panels, stick = {}, buttons = {} }
end

-- Closes the innermost open overlay opened from the panel, or from an overlay of it.
local function dismiss(state: Traversal, panel: records.Panel): boolean
  local innermost: records.Panel? = nil
  for _, candidate in state.panels() do
    if candidate.overlay and not candidate.dead then
      local opener: records.Panel? = candidate.overlay.opener
      while opener do
        if opener == panel then
          innermost = candidate
          break
        end
        opener = if opener.overlay then opener.overlay.opener else nil
      end
    end
  end
  if innermost and innermost.overlay then
    innermost.overlay.portal.handle:emit 'onDismiss'
    return true
  end
  return false
end

local function actions(state: Traversal): focus.Actions
  return {
    dispatch = state.env.dispatch,
    dismiss = function(panel: records.Panel): boolean
      return dismiss(state, panel)
    end,
  }
end

-- Registers the panel with the focus service, or registers it again when whether it wants the keyboard changed.
local function session(state: Traversal, panel: records.Panel, wantsKeyboard: boolean): focusContract.TargetHandle
  local current = panel.session
  if current and not current.handle.dead and current.wantsKeyboard == wantsKeyboard then
    return current.handle
  end
  if current and not current.handle.dead then
    current.handle:destroy()
  end
  local receiver: focusContract.Receiver = {
    key = function(event: focusContract.KeyEvent): boolean
      return focus.key(state.env, actions(state), panel, {
        kind = 'key',
        code = event.code,
        modifiers = event.modifiers,
        isRepeat = event.isRepeat,
        source = event.source,
      })
    end,
    text = function(text: string): boolean
      local node = panel.focused
      if node and not node.dead then
        return state.env.dispatch(node, { kind = 'text', text = text })
      end
      return false
    end,
  }
  local handle = state.service:register(state.context, {
    kind = 'local',
    receiver = receiver,
    keymapSeat = nil,
    wantsKeyboard = wantsKeyboard,
  })
  panel.session = { handle = handle, wantsKeyboard = wantsKeyboard }
  return handle
end

-- Focuses a node. A text node takes session focus so typing reaches it; a pointer node becomes the panel's focused
-- node without it, and does not take focus from a focused text node in its panel.
function traversal.focusNode(state: Traversal, node: records.Node, visible: boolean): boolean
  local policy = focus.policy(state.env, node)
  if policy == 'none' then
    return false
  end
  local panel = node.panel
  local current = panel.focused
  if
    policy == 'pointer'
    and not visible
    and current
    and current ~= node
    and focus.policy(state.env, current) == 'text'
  then
    return false
  end
  focus.set(panel, node, visible)
  if policy == 'text' then
    session(state, panel, true):focus()
  elseif visible then
    session(state, panel, false):focus()
  end
  return true
end

function traversal.blurNode(state: Traversal, node: records.Node): ()
  local panel = node.panel
  if panel.focused == node then
    focus.set(panel, nil, false)
    local current = panel.session
    if current and current.wantsKeyboard and not current.handle.dead then
      current.handle:blur()
    end
  end
end

-- The panel whose target holds session focus, if a host panel holds it.
function traversal.active(state: Traversal): records.Panel?
  local focused = state.service:focused()
  if not focused then
    return nil
  end
  for _, panel in state.panels() do
    if panel.session and panel.session.handle == focused then
      return panel
    end
  end
  return nil
end

-- Delivers a traversal key to the panel holding session focus.
function traversal.key(
  state: Traversal,
  code: number,
  source: 'controller' | 'physical' | 'virtual',
  modifiers: { string }?
): boolean
  local panel = traversal.active(state)
  if not panel then
    return false
  end
  return focus.key(state.env, actions(state), panel, {
    kind = 'key',
    code = code,
    modifiers = modifiers or {},
    isRepeat = false,
    source = source,
  })
end

-- Moves session focus to the next panel that has a focusable node, focusing its first node visibly.
function traversal.nextPanel(state: Traversal): boolean
  local panels: { records.Panel } = {}
  for _, panel in state.panels() do
    if panel.visible and not panel.dead and panel.overlay == nil and #focus.order(state.env, panel) > 0 then
      table.insert(panels, panel)
    end
  end
  if #panels == 0 then
    return false
  end
  local current = traversal.active(state)
  local index = if current then table.find(panels, current) else nil
  local next = panels[if index then index % #panels + 1 else 1]
  local target = next.focused or focus.step(state.env, next, 1)
  if target then
    return traversal.focusNode(state, target, true)
  end
  return false
end

local function stickDirection(x: number, y: number): string?
  if math.max(math.abs(x), math.abs(y)) < STICK_PRESS then
    return nil
  end
  if math.abs(x) > math.abs(y) then
    return if x > 0 then 'right' else 'left'
  end
  return if y > 0 then 'up' else 'down'
end

local DIRECTION_CODES: { [string]: number } = {
  up = keys.CODES.up,
  down = keys.CODES.down,
  left = keys.CODES.left,
  right = keys.CODES.right,
}

-- Reads each controller's thumbstick and face buttons. They traverse only while a host panel holds session focus
-- and no ray points at a host panel, so they do not take the thumbstick from scrolling or the session.
function traversal.controllers(state: Traversal, pointing: boolean): ()
  local headset = lovr.headset
  if not headset or not headset.getAxis or not headset.isDown then
    return
  end
  local active = traversal.active(state)
  local hands: { 'hand/left' | 'hand/right' } = { 'hand/left', 'hand/right' }
  for _, hand in hands do
    local device = hand
    local buttons = state.buttons[hand] or {}
    state.buttons[hand] = buttons
    local tracked = headset.isTracked(device)
    local x, y = 0, 0
    if tracked then
      x, y = headset.getAxis(device, 'thumbstick')
    end
    local direction = stickDirection(x or 0, y or 0)
    local previous = state.stick[hand]
    if direction and direction ~= previous then
      state.stick[hand] = direction
      if active and not pointing then
        traversal.key(state, DIRECTION_CODES[direction], 'controller')
      end
    elseif not direction and math.max(math.abs(x or 0), math.abs(y or 0)) < STICK_RELEASE then
      state.stick[hand] = nil
    end
    local faces: { [string]: number } = { a = keys.CODES.enter, b = keys.CODES.escape }
    for button, code in faces do
      local down = tracked and headset.isDown(device, button :: any)
      if down and not buttons[button] and active and not pointing then
        traversal.key(state, code, 'controller')
      end
      buttons[button] = down
    end
  end
end

-- Ends a panel's registration with the focus service.
function traversal.release(panel: records.Panel): ()
  local current = panel.session
  panel.session = nil
  if current and not current.handle.dead then
    current.handle:destroy()
  end
end

return traversal
