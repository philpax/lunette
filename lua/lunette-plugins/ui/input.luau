-- Routes a surface gesture to its original control without changing unrelated keyboard focus.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local surface = require '@lunette-contracts/surface'
local records = require '@lunette-plugins/ui/panel-state'
local geometry = require '@lunette-plugins/ui/geometry'
local order = require '@lunette-plugins/ui/control-order'
local protected = require '@lunette-plugins/protected'
local panelGeometry = require './panel-geometry'

local input = {}

type Panel = records.Panel
type Control = records.Control

local function canvas(panel: Panel): ui.Bounds
  return panelGeometry.prepare(panel).clip
end

function input.bounds(panel: Panel, control: Control): ui.Bounds?
  return geometry.intersect(control.bounds, canvas(panel))
end

local function contains(bounds: ui.Bounds?, x: number?, y: number?): boolean
  return bounds ~= nil and x ~= nil and y ~= nil and geometry.contains(bounds, { x = x, y = y })
end

local function items(panel: Panel, control: Control): { read [number]: ui.ItemDescription }
  local visible = input.bounds(panel, control)
  return if visible then control.widget.items(visible, control.theme) else {}
end

local function itemAt(panel: Panel, control: Control, x: number?, y: number?): string?
  local result: string? = nil
  for _, item in items(panel, control) do
    if item.enabled and contains(item.bounds, x, y) then
      result = item.id
    end
  end
  return result
end

local function owned(panel: Panel, control: Control?): boolean
  return panel.context:active()
    and panel.context:owns(panel.owner)
    and (control == nil or panel.context:owns(control.owner))
end

local function interactive(panel: Panel, control: Control?): boolean
  return owned(panel, control)
    and not panel.dead
    and panel.visible
    and not panel.cancelling
    and (control == nil or (not control.dead and control.enabled))
end

local function pick(panel: Panel, x: number?, y: number?): Control?
  local result: Control? = nil
  for _, control in ipairs(order.ordered(panel.controls)) do
    if interactive(panel, control) and contains(input.bounds(panel, control), x, y) then
      result = control
    end
  end
  return result
end

local function deliver(
  panel: Panel,
  control: Control,
  event: surface.PointerEvent,
  item: string?,
  terminal: boolean?
): ()
  local allowed = if terminal
    then (panel.owner :: plugin.Context):active() and (control.owner :: plugin.Context):active()
    else interactive(panel, control)
  if not allowed then
    return
  end
  protected.call('ui: ' .. plugin.ownerLabel(control.owner) .. ': ' .. control.id .. ' pointer', function(): ()
    control.widget.pointer(event, item)
  end)
end

local function getCapture(
  panel: Panel,
  pointer: surface.Pointer,
  button: lunette.PointerButton,
  terminal: boolean
): records.Capture?
  local buttons = panel.captures[pointer]
  local capture = if buttons then buttons[button] else nil
  if not capture or not buttons then
    return nil
  end
  if terminal then
    buttons[button] = nil
    if next(buttons) == nil then
      panel.captures[pointer] = nil
    end
  end
  return capture
end

local function hover(panel: Panel, pointer: surface.Pointer, selected: Control?, event: surface.PointerEvent): ()
  local previous = panel.hovered[pointer]
  if previous == selected then
    return
  end
  panel.hovered[pointer] = selected
  if previous then
    local copied: surface.PointerEvent = {
      kind = 'leave',
      pointer = pointer,
      x = event.x,
      y = event.y,
      inside = false,
      captured = false,
    }
    deliver(panel, previous, table.freeze(copied), nil)
  end
  if selected and panel.hovered[pointer] == selected then
    local copied: surface.PointerEvent = {
      kind = 'enter',
      pointer = pointer,
      x = event.x,
      y = event.y,
      inside = true,
      captured = false,
    }
    deliver(panel, selected, table.freeze(copied), itemAt(panel, selected, event.x, event.y))
  end
end

local function capturedByAnother(panel: Panel, control: Control, pointer: surface.Pointer): boolean
  if not control.exclusive then
    return false
  end
  for other, buttons in panel.captures do
    if other ~= pointer then
      for _, capture in buttons do
        if capture.control == control then
          return true
        end
      end
    end
  end
  return false
end

-- Destruction, disabling, and geometry replacement detach local state before any observer runs.
function input.prepareCancel(panel: Panel, selected: Control?, reason: surface.CancelReason): () -> ()
  local pending: { () -> () } = {}
  local affected: { [surface.Pointer]: boolean } = {}
  local function consume(delivery: records.PendingInput): ()
    local index = table.find(panel.pendingInput, delivery)
    if index then
      table.remove(panel.pendingInput, index)
      delivery.run()
    end
  end
  -- Nested destruction consumes the original pending terminals before its target inverse runs.
  for _, delivery in ipairs(table.clone(panel.pendingInput)) do
    if not selected or delivery.control == selected then
      pending[#pending + 1] = function(): ()
        consume(delivery)
      end
    end
  end
  local function queue(control: Control, event: surface.PointerEvent, item: string?): ()
    local delivery: records.PendingInput = {
      control = control,
      run = function(): ()
        deliver(panel, control, event, item, true)
      end,
    }
    panel.pendingInput[#panel.pendingInput + 1] = delivery
    pending[#pending + 1] = function(): ()
      consume(delivery)
    end
  end
  for pointer, buttons in panel.captures do
    for button, capture in buttons do
      if not selected or capture.control == selected then
        buttons[button] = nil
        affected[pointer] = true
        local copied: surface.PointerEvent = {
          kind = 'cancel',
          pointer = pointer,
          button = button,
          reason = reason,
          inside = false,
          captured = true,
        }
        queue(capture.control, table.freeze(copied), capture.item)
      end
    end
    if next(buttons) == nil then
      panel.captures[pointer] = nil
    end
  end
  for pointer, control in panel.hovered do
    if not selected or control == selected then
      panel.hovered[pointer] = nil
      local copied: surface.PointerEvent = { kind = 'leave', pointer = pointer, inside = false, captured = false }
      queue(control, table.freeze(copied), nil)
    end
  end
  if not selected then
    local offered = panel.surface
    for pointer in panel.pointerHover do
      affected[pointer] = true
    end
    panel.pointerHover = {}
    if offered then
      for pointer in affected do
        pending[#pending + 1] = function(): ()
          pointer:cancel(offered, reason)
        end
      end
    end
  end
  return function(): ()
    local wasCancelling = panel.cancelling
    panel.cancelling = true
    local failures: { string } = {}
    for _, inverse in ipairs(pending) do
      local ok, failure = pcall(inverse)
      if not ok then
        failures[#failures + 1] = tostring(failure)
      end
    end
    panel.cancelling = wasCancelling
    if #failures > 0 then
      error('ui: pointer cleanup: ' .. table.concat(failures, '; '), 0)
    end
  end
end

function input.cancel(panel: Panel, selected: Control?, reason: surface.CancelReason): ()
  input.prepareCancel(panel, selected, reason)()
end

function input.event(panel: Panel, event: surface.PointerEvent): ()
  if event.kind ~= 'cancel' and event.kind ~= 'leave' then
    panel.refresh()
  end
  if not interactive(panel, nil) then
    return
  end
  local pointer, x, y = event.pointer, event.x, event.y
  if event.kind == 'enter' then
    panel.pointerHover[pointer] = true
    return
  end
  if event.kind == 'leave' then
    panel.pointerHover[pointer] = nil
    hover(panel, pointer, nil, event)
    return
  end
  if event.kind == 'move' then
    local button = event.button
    if button == nil then
      hover(panel, pointer, if event.inside then pick(panel, x, y) else nil, event)
      return
    end
    local capture = getCapture(panel, pointer, button, false)
    if not capture then
      return
    end
    local selected = capture.control
    local copied: surface.PointerEvent = {
      kind = 'move',
      pointer = pointer,
      x = x,
      y = y,
      button = button,
      captured = event.captured,
      inside = selected.enabled
        and not selected.dead
        and event.inside
        and contains(input.bounds(panel, selected), x, y),
    }
    deliver(panel, selected, table.freeze(copied), itemAt(panel, selected, x, y))
    return
  end
  if event.kind == 'press' then
    local selected = if event.inside then pick(panel, x, y) else nil
    if not selected or capturedByAnother(panel, selected, pointer) then
      return
    end
    local buttons = panel.captures[pointer] or {}
    panel.captures[pointer] = buttons
    local item = itemAt(panel, selected, x, y)
    local capture: records.Capture = { control = selected, item = item }
    buttons[event.button] = capture
    deliver(panel, selected, event, item)
    if
      event.button == 'left'
      and interactive(panel, selected)
      and getCapture(panel, pointer, event.button, false) == capture
    then
      pointer:vibrate { strength = selected.theme.hapticStrength, duration = selected.theme.hapticDuration }
    end
    return
  end
  if event.kind == 'release' then
    local capture = getCapture(panel, pointer, event.button, true)
    if not capture then
      return
    end
    local selected = capture.control
    local copied: surface.PointerEvent = {
      kind = 'release',
      pointer = pointer,
      x = x,
      y = y,
      button = event.button,
      captured = event.captured,
      inside = selected.enabled
        and not selected.dead
        and event.inside
        and contains(input.bounds(panel, selected), x, y),
    }
    deliver(panel, selected, table.freeze(copied), itemAt(panel, selected, x, y))
    return
  end
  if event.kind == 'cancel' then
    local capture = getCapture(panel, pointer, event.button, true)
    if not capture then
      return
    end
    local selected = capture.control
    local copied: surface.PointerEvent = {
      kind = 'cancel',
      pointer = pointer,
      x = x,
      y = y,
      button = event.button,
      reason = event.reason,
      captured = event.captured,
      inside = selected.enabled
        and not selected.dead
        and event.inside
        and contains(input.bounds(panel, selected), x, y),
    }
    deliver(panel, selected, table.freeze(copied), capture.item, true)
    return
  end
  if event.kind == 'scroll' then
    local selected = if event.inside then pick(panel, x, y) else nil
    if selected then
      deliver(panel, selected, event, itemAt(panel, selected, x, y))
    end
    return
  end
end

return input
