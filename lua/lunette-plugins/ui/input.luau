-- Routes a surface gesture to its original control without changing unrelated keyboard focus.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local records = require '@lunette-plugins/ui/panel-state'
local geometry = require '@lunette-plugins/ui/geometry'
local protected = require '@lunette-plugins/protected'
local cleanup = require './cleanup'
local panelGeometry = require './panel-geometry'
local vocabulary = require '@lunette-contracts/vocabulary'

local input = {}

type Panel = records.Panel
type Control = records.Control

function input.bounds(panel: Panel, control: Control): ui.Bounds?
  return geometry.intersect(control.bounds, panelGeometry.prepare(panel).clip)
end

-- Controls paint and pick from low to high z, with later registration above earlier controls on ties.
function input.ordered(controls: { read [number]: Control }): { Control }
  local result = table.clone(controls) :: { Control }
  table.sort(result, function(first: Control, second: Control): boolean
    return first.z < second.z or (first.z == second.z and first.order < second.order)
  end)
  return result
end

local function itemAt(panel: Panel, control: Control, x: number?, y: number?): string?
  local visible = input.bounds(panel, control)
  if not visible then
    return nil
  end
  local result: string? = nil
  for _, item in control.widget.items(visible, control.theme) do
    local bounds = item.bounds
    if item.enabled and bounds and geometry.contains(bounds, x, y) then
      result = item.id
    end
  end
  return result
end

local function interactive(panel: Panel, control: Control?): boolean
  return panel.context:active()
    and panel.context:owns(panel.owner)
    and not panel.dead
    and panel.visible
    and not panel.cancelling
    and (control == nil or (panel.context:owns(control.owner) and not control.dead and control.enabled))
end

local function inside(panel: Panel, control: Control, x: number?, y: number?): boolean
  local visible = input.bounds(panel, control)
  return visible ~= nil and geometry.contains(visible, x, y)
end

local function pick(panel: Panel, x: number?, y: number?): Control?
  local result: Control? = nil
  for _, control in input.ordered(panel.controls) do
    if interactive(panel, control) and inside(panel, control, x, y) then
      result = control
    end
  end
  return result
end

-- A terminal event reaches a control whose owner is still running even after it stopped being interactive.
local function deliver(
  panel: Panel,
  control: Control,
  event: vocabulary.PointerEvent,
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

local function takeCapture(
  panel: Panel,
  pointer: vocabulary.Pointer,
  button: lunette.PointerButton,
  terminal: boolean
): records.Capture?
  local buttons = panel.captures[pointer]
  local capture = if buttons then buttons[button] else nil
  if capture and buttons and terminal then
    buttons[button] = nil
    if next(buttons) == nil then
      panel.captures[pointer] = nil
    end
  end
  return capture
end

local function hover(panel: Panel, pointer: vocabulary.Pointer, selected: Control?, event: vocabulary.PointerEvent): ()
  local previous = panel.hovered[pointer]
  if previous == selected then
    return
  end
  panel.hovered[pointer] = selected
  if previous then
    local copied: vocabulary.PointerEvent =
      { kind = 'leave', pointer = pointer, x = event.x, y = event.y, inside = false, captured = false }
    deliver(panel, previous, table.freeze(copied), nil)
  end
  if selected and panel.hovered[pointer] == selected then
    local copied: vocabulary.PointerEvent =
      { kind = 'enter', pointer = pointer, x = event.x, y = event.y, inside = true, captured = false }
    deliver(panel, selected, table.freeze(copied), itemAt(panel, selected, event.x, event.y))
  end
end

local function capturedByAnother(panel: Panel, control: Control, pointer: vocabulary.Pointer): boolean
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

-- Forwards a captured gesture event, recomputing whether it lies inside the capturing control.
local function forward(panel: Panel, capture: records.Capture, event: vocabulary.PointerEvent, terminal: boolean): ()
  local selected = capture.control
  local x, y = event.x, event.y
  local copied = table.clone(event) :: { [string]: unknown }
  copied.inside = selected.enabled and not selected.dead and event.inside and inside(panel, selected, x, y)
  local item = if event.kind == 'cancel' then capture.item else itemAt(panel, selected, x, y)
  deliver(panel, selected, (table.freeze(copied) :: unknown) :: vocabulary.PointerEvent, item, terminal)
end

-- Cancellation detaches the matching captures and hovers before any owner observes the cancel or leave.
function input.cancel(panel: Panel, selected: Control?, reason: vocabulary.CancelReason): ()
  local operations: { () -> () } = {}
  local affected: { [vocabulary.Pointer]: boolean } = {}
  for pointer, buttons in panel.captures do
    for button, capture in buttons do
      if not selected or capture.control == selected then
        buttons[button] = nil
        affected[pointer] = true
        local copied: vocabulary.PointerEvent =
          { kind = 'cancel', pointer = pointer, button = button, reason = reason, inside = false, captured = true }
        operations[#operations + 1] = function(): ()
          deliver(panel, capture.control, table.freeze(copied), capture.item, true)
        end
      end
    end
    if next(buttons) == nil then
      panel.captures[pointer] = nil
    end
  end
  for pointer, control in panel.hovered do
    if not selected or control == selected then
      panel.hovered[pointer] = nil
      local copied: vocabulary.PointerEvent = { kind = 'leave', pointer = pointer, inside = false, captured = false }
      operations[#operations + 1] = function(): ()
        deliver(panel, control, table.freeze(copied), nil, true)
      end
    end
  end
  local offered = panel.surface
  if not selected then
    for pointer in panel.pointerHover do
      affected[pointer] = true
    end
    panel.pointerHover = {}
    if offered then
      for pointer in affected do
        operations[#operations + 1] = function(): ()
          pointer:cancel(offered, reason)
        end
      end
    end
  end
  local wasCancelling = panel.cancelling
  panel.cancelling = true
  local ok, failure = pcall(cleanup.run, 'ui: pointer cleanup', operations)
  panel.cancelling = wasCancelling
  if not ok then
    error(failure, 0)
  end
end

function input.event(panel: Panel, event: vocabulary.PointerEvent): ()
  if event.kind ~= 'cancel' and event.kind ~= 'leave' then
    panel.refresh()
  end
  if not interactive(panel, nil) then
    return
  end
  local pointer, x, y = event.pointer, event.x, event.y
  if event.kind == 'enter' then
    panel.pointerHover[pointer] = true
  elseif event.kind == 'leave' then
    panel.pointerHover[pointer] = nil
    hover(panel, pointer, nil, event)
  elseif event.kind == 'move' then
    local button = event.button
    if button == nil then
      hover(panel, pointer, if event.inside then pick(panel, x, y) else nil, event)
      return
    end
    local capture = takeCapture(panel, pointer, button, false)
    if capture then
      forward(panel, capture, event, false)
    end
  elseif event.kind == 'press' then
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
      and takeCapture(panel, pointer, event.button, false) == capture
    then
      pointer:vibrate { strength = selected.theme.hapticStrength, duration = selected.theme.hapticDuration }
    end
  elseif event.kind == 'release' then
    local capture = takeCapture(panel, pointer, event.button, true)
    if capture then
      forward(panel, capture, event, false)
    end
  elseif event.kind == 'cancel' then
    local capture = takeCapture(panel, pointer, event.button, true)
    if capture then
      forward(panel, capture, event, true)
    end
  elseif event.kind == 'scroll' then
    local selected = if event.inside then pick(panel, x, y) else nil
    if selected then
      deliver(panel, selected, event, itemAt(panel, selected, x, y))
    end
  end
end

return input
