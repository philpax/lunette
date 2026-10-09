-- Independent gesture delivery retains rectangular control targets within a rounded panel silhouette.

local quad = require '@lunette-contracts/quad'
local appearance = require './appearance'
local geometry = require './geometry'
local items = require './items'
local surfaceGeometry = require './surface-geometry'

local routing = {}

function routing.install(panel)
  local pendingTerminals = {}
  local cancelling = false
  local function interactive(control)
    return panel.live() and panel.visible and not cancelling and (not control or (control.live() and control.enabled))
  end
  local function emit(control, event, terminal)
    if not terminal and not interactive(control) then
      return
    end
    if control.kind == 'text-field' and control.pointer then
      appearance.focusCallback(control, 'pointer', function()
        control.pointer(event)
      end)
    end
    local onPointer = control.options.onPointer
    if control.kind == 'region' and onPointer then
      appearance.callback(control, 'onPointer', function()
        onPointer(event)
      end, terminal)
    end
  end
  local function consume(delivery)
    local index = table.find(pendingTerminals, delivery)
    if index then
      table.remove(pendingTerminals, index)
      emit(delivery.control, delivery.event, true)
    end
  end
  function panel.cancel(control, reason)
    local deliveries, affected = {}, {}
    -- Nested destruction drains the selected terminals before clearing its observer.
    for _, delivery in ipairs(table.clone(pendingTerminals)) do
      if not control or delivery.control == control then
        deliveries[#deliveries + 1] = delivery
      end
    end
    local function queue(target, event)
      local delivery = { control = target, event = table.freeze(event) }
      pendingTerminals[#pendingTerminals + 1] = delivery
      deliveries[#deliveries + 1] = delivery
    end
    for pointer, gestures in panel.gestures do
      for button, gesture in gestures do
        if not control or gesture.control == control then
          gestures[button] = nil
          gesture.control.presses[pointer] = nil
          affected[pointer] = true
          queue(gesture.control, {
            kind = 'cancel',
            pointer = pointer,
            button = button,
            captured = true,
            inside = false,
            reason = reason,
          })
        end
      end
      if not next(gestures) then
        panel.gestures[pointer] = nil
      end
    end
    for _, candidate in panel.controls do
      if not control or candidate == control then
        for pointer in candidate.hovered do
          candidate.hovered[pointer] = nil
          affected[pointer] = true
          queue(candidate, { kind = 'leave', pointer = pointer, captured = false, inside = false })
        end
      end
    end
    local wasCancelling = cancelling
    cancelling = true
    local failures = {}
    for _, delivery in deliveries do
      local ok, message = pcall(consume, delivery)
      if not ok then
        failures[#failures + 1] = tostring(message)
      end
    end
    for pointer in affected do
      local ok, message = pcall(function()
        pointer:cancel(panel.surface, reason)
      end)
      if not ok then
        failures[#failures + 1] = tostring(message)
      end
    end
    cancelling = wasCancelling
    if #failures > 0 then
      error('ui substitute: pointer cleanup: ' .. table.concat(failures, '\n'), 0)
    end
  end
  local function hit(x, y)
    local winner, itemId
    for _, control in panel.controls do
      if
        control.live()
        and control.enabled
        and geometry.contains(geometry.intersect(control.bounds, panel.clip()), x, y)
        and (not winner or control.z >= winner.z)
      then
        winner, itemId = control, nil
        for _, item in items.rows(control) do
          if item.enabled and geometry.contains(item.bounds, x, y) then
            itemId = item.id
            break
          end
        end
      end
    end
    return winner, itemId
  end
  local function quadTarget(backFace)
    return {
      pose = panel.surface.pose,
      width = panel.surface.width,
      height = panel.surface.height,
      pixelWidth = panel.surface.pixelWidth,
      pixelHeight = panel.surface.pixelHeight,
      backFace = backFace,
    }
  end
  function panel.surface.raycast(_, origin, direction, backFace)
    panel.refresh()
    if not panel.live() or not panel.visible then
      return nil, nil, nil
    end
    local x, y, distance = quad.hit(quadTarget(backFace), origin, direction)
    if not surfaceGeometry.contains(panel, x, y) then
      return nil, nil, nil
    end
    return x, y, distance
  end
  function panel.surface.project(_, origin, direction, backFace)
    panel.refresh()
    if not panel.live() or not panel.visible then
      return nil, nil, nil
    end
    return quad.project(quadTarget(backFace), origin, direction)
  end
  function panel.surface.onPointer(_, event)
    if event.kind ~= 'cancel' and event.kind ~= 'leave' then
      panel.refresh()
    end
    local pointer, button = event.pointer, event.button
    local gestures = panel.gestures[pointer] or {}
    if event.kind == 'cancel' then
      local gesture = gestures[button]
      if gesture then
        gestures[button] = nil
        if not next(gestures) then
          panel.gestures[pointer] = nil
        end
        gesture.control.presses[pointer] = nil
        emit(gesture.control, event, true)
      end
      return
    end
    if not interactive() then
      return
    end
    local control, item
    if event.inside ~= false and surfaceGeometry.contains(panel, event.x, event.y) then
      control, item = hit(event.x, event.y)
    end
    for _, candidate in panel.controls do
      candidate.hovered[pointer] = if event.kind ~= 'leave' and candidate == control then true else nil
    end
    if event.kind == 'press' and control then
      if control.exclusive and next(control.presses) then
        return
      end
      local gesture = { control = control, item = item, revision = panel.revision }
      panel.gestures[pointer] = gestures
      gestures[button] = gesture
      control.presses[pointer] = true
      local function captured()
        return interactive(control)
          and panel.gestures[pointer] == gestures
          and gestures[button] == gesture
          and gesture.revision == panel.revision
      end
      if button == 'left' and control.target then
        control.target:focus()
      end
      if not captured() then
        return
      end
      emit(control, event)
    elseif event.kind == 'release' then
      local gesture = gestures[button]
      gestures[button] = nil
      if not gesture then
        return
      end
      local pressed = gesture.control
      pressed.presses[pointer] = nil
      local revision = panel.revision
      emit(pressed, event)
      if
        not pressed.live()
        or not pressed.enabled
        or not panel.visible
        or panel.revision ~= revision
        or button ~= 'left'
        or pressed ~= control
        or not event.inside
        or gesture.revision ~= panel.revision
      then
        return
      end
      if control.kind == 'button' then
        appearance.callback(control, 'onActivate', control.options.onActivate)
      elseif control.kind == 'choice' and not gesture.item then
        control.handle:setOpen(not control.opened)
      elseif (control.kind == 'choice' or control.kind == 'list') and item and item == gesture.item then
        control.chosen = item
        if control.kind == 'choice' then
          control.handle:setOpen(false)
        end
        if control.options.onChange then
          appearance.callback(control, 'onChange', function()
            control.options.onChange(item)
          end)
        end
      end
    elseif event.kind == 'scroll' and control and (control.kind == 'choice' or control.kind == 'list') then
      control.handle:scroll(event.dy)
    elseif event.captured and event.button and gestures[event.button] then
      emit(gestures[event.button].control, event)
    elseif control then
      emit(control, event)
    end
  end
end

return routing
