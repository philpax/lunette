-- Focus within panels and traversal: which node a panel has focused, how keys reach it, and how unconsumed keys
-- move focus, activate, and dismiss.

local uiHost = require '@lunette-contracts/ui-host'
local keys = require '@lunette-contracts/keys'
local records = require './records'
local handles = require './handles'

local focus = {}

export type Direction = 'up' | 'down' | 'left' | 'right'

-- A node's focus policy. A node that takes no input, such as a disabled control, is not focusable.
function focus.policy(env: records.Environment, node: records.Node): 'text' | 'pointer' | 'none'
  local declared = node.kind.registration.focus
  if declared == nil or declared == 'none' or node.dead then
    return 'none'
  end
  local interactive = node.kind.registration.interactive
  if interactive then
    local enabled = false
    env.protect(`ui: {node.kind.name} interactive`, function(): ()
      enabled = interactive(node.props) == true
    end)
    if not enabled then
      return 'none'
    end
  end
  if node.props.disabledReason ~= nil or node.props.disabled == true then
    return 'none'
  end
  return declared
end

local function refresh(node: records.Node): ()
  handles.hostChanged(node)
end

-- Moves the panel's focus to the node, or clears it. A ring shows only for focus that traversal moved.
function focus.set(panel: records.Panel, node: records.Node?, visible: boolean): ()
  local previous = panel.focused
  if previous == node then
    if node and node.host.focusVisible ~= visible then
      node.host.focusVisible = visible
      refresh(node)
    end
    return
  end
  if previous then
    previous.host.focused, previous.host.focusVisible, previous.host.engaged = false, false, false
    refresh(previous)
  end
  panel.focused = node
  if node then
    node.host.focused, node.host.focusVisible = true, visible
    refresh(node)
    -- Focus that traversal or a program moved is brought into view; a pointer already shows where it pressed.
    if visible then
      handles.scrollIntoView(node, node.handle.theme.spacing.sm)
    end
  end
end

-- The focusable nodes of a panel in tree order.
function focus.order(env: records.Environment, panel: records.Panel): { records.Node }
  local list: { records.Node } = {}
  local function visit(node: records.Node): ()
    if focus.policy(env, node) ~= 'none' then
      table.insert(list, node)
    end
    for _, child in node.children do
      visit(child)
    end
  end
  if panel.root then
    visit(panel.root)
  end
  return list
end

-- Sequential traversal: the next or previous focusable node, wrapping around the panel.
function focus.step(env: records.Environment, panel: records.Panel, delta: number): records.Node?
  local order = focus.order(env, panel)
  if #order == 0 then
    return nil
  end
  local index = if panel.focused then table.find(order, panel.focused) else nil
  if not index then
    return if delta > 0 then order[1] else order[#order]
  end
  return order[(index - 1 + delta) % #order + 1]
end

-- Directional traversal: the nearest focusable node whose centre lies in the direction, weighting distance across
-- the direction more heavily so that a node in the same row or column wins.
function focus.toward(env: records.Environment, panel: records.Panel, direction: Direction): records.Node?
  local from = panel.focused
  if not from then
    return focus.step(env, panel, 1)
  end
  local fx, fy = from.x + from.width / 2, from.y + from.height / 2
  local best: records.Node? = nil
  local bestScore = math.huge
  for _, candidate in focus.order(env, panel) do
    if candidate ~= from then
      local dx = candidate.x + candidate.width / 2 - fx
      local dy = candidate.y + candidate.height / 2 - fy
      local along = if direction == 'right'
        then dx
        elseif direction == 'left' then -dx
        elseif direction == 'down' then dy
        else -dy
      local across = if direction == 'left' or direction == 'right' then math.abs(dy) else math.abs(dx)
      if along > 1e-4 then
        local score = along + across * 3
        if score < bestScore then
          best, bestScore = candidate, score
        end
      end
    end
  end
  return best
end

local function has(modifiers: { read [number]: string }, name: string): boolean
  for _, modifier in modifiers do
    if modifier == name then
      return true
    end
  end
  return false
end

local DIRECTIONS: { [number]: Direction } = {
  [keys.CODES.up] = 'up',
  [keys.CODES.down] = 'down',
  [keys.CODES.left] = 'left',
  [keys.CODES.right] = 'right',
}

export type Actions = {
  read dispatch: (records.Node, uiHost.Event) -> boolean,
  -- Closes the innermost open overlay of the panel's chain, answering whether one closed.
  read dismiss: (records.Panel) -> boolean,
}

-- Delivers a key to the panel's focused node, and applies traversal when no node consumes it. Answers whether the
-- key was used.
export type KeyEvent = {
  read kind: 'key',
  read code: number,
  read modifiers: { read [number]: string },
  read isRepeat: boolean,
  read source: ('physical' | 'virtual' | 'controller')?,
}

function focus.key(env: records.Environment, actions: Actions, panel: records.Panel, event: KeyEvent): boolean
  local code, modifiers, isRepeat = event.code, event.modifiers, event.isRepeat
  local node = panel.focused
  if node and not node.dead then
    if actions.dispatch(node, event) then
      return true
    end
  end
  local codes = keys.CODES
  if code == codes.tab then
    local target = focus.step(env, panel, if has(modifiers, 'shift') then -1 else 1)
    if target then
      focus.set(panel, target, true)
    end
    return target ~= nil
  end
  local direction = DIRECTIONS[code]
  if direction then
    local target = focus.toward(env, panel, direction)
    if target then
      focus.set(panel, target, true)
      return true
    end
    return false
  end
  if (code == codes.enter or code == codes.space or code == codes.keypadEnter) and node and not isRepeat then
    if node.kind.registration.engage then
      node.host.engaged = not node.host.engaged
      refresh(node)
      return true
    end
    actions.dispatch(node, { kind = 'activate' })
    return true
  end
  if code == codes.escape then
    if node and node.host.engaged then
      node.host.engaged = false
      refresh(node)
      return true
    end
    if actions.dismiss(panel) then
      return true
    end
    if node then
      focus.set(panel, nil, false)
      return true
    end
  end
  return false
end

return focus
