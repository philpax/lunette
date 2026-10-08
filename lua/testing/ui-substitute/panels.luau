-- Public quad surfaces route gestures and describe the same logical panel geometry they draw.

local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local quad = require '@lunette-contracts/quad'
local protected = require '@lunette-plugins/protected'
local appearance = require './appearance'
local geometry = require './geometry'
local items = require './items'
local controls = require './controls'

local panels = {}

function panels.new(provider, owner, options)
  for _, value in { options.width, options.height, options.logicalWidth, options.logicalHeight } do
    assert(geometry.finite(value) and value > 0, 'ui substitute: panel dimensions are finite and positive')
  end
  assert(type(options.name) == 'string' and options.name ~= '', 'ui substitute: panel name is nonempty')
  local panel = {
    dead = false,
    provider = provider,
    owner = owner,
    name = options.name,
    controls = {},
    revision = 1,
    visible = options.visible ~= false,
    overrides = appearance.copyOverrides(options.theme),
    drawHook = options.draw,
    gestures = {},
  }
  panel.surface = {
    dead = false,
    kind = nil,
    grabbable = options.grabbable ~= false,
    grabTarget = if options.grabTarget
      then function()
        return options.grabTarget
      end
      else nil,
    pose = if options.pose then lovr.math.newMat4(options.pose) else lovr.math.newMat4(),
    width = options.width,
    height = options.height,
    pixelWidth = options.logicalWidth,
    pixelHeight = options.logicalHeight,
  }
  local handle = { dead = false }
  function panel.live()
    return not panel.dead and provider.context:owns(owner)
  end
  function panel.theme()
    return appearance.theme(appearance.defaultTheme, panel.overrides)
  end
  panel.theme()
  function panel.clip()
    return { x = 0, y = 0, width = panel.surface.pixelWidth, height = panel.surface.pixelHeight }
  end
  local pendingTerminals = {}
  local cancelling = false
  local function interactive(control)
    return panel.live() and panel.visible and not cancelling and (not control or (control.live() and control.enabled))
  end
  local function emit(control, event, terminal)
    if not terminal and not interactive(control) then
      return
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
  function panel.surface.raycast(_, origin, direction)
    if not panel.live() or not panel.visible then
      return nil, nil, nil
    end
    return quad.hit(panel.surface, origin, direction)
  end
  function panel.surface.project(_, origin, direction)
    if not panel.live() or not panel.visible then
      return nil, nil, nil
    end
    return quad.project(panel.surface, origin, direction)
  end
  function panel.surface.onPointer(_, event)
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
    local control, item = hit(event.x, event.y)
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
  function handle.setPose(_: ui.Panel, pose: Mat4)
    if not panel.live() then
      return
    end
    panel.surface.pose:set(pose)
    panel.revision += 1
    for _, gestures in panel.gestures do
      for _, gesture in gestures do
        gesture.revision = panel.revision
      end
    end
  end
  function handle.setSize(_: ui.Panel, width: number, height: number, logicalWidth: number?, logicalHeight: number?)
    if not panel.live() then
      return
    end
    for _, value in
      { width, height, logicalWidth or panel.surface.pixelWidth, logicalHeight or panel.surface.pixelHeight }
    do
      assert(geometry.finite(value) and value > 0, 'ui substitute: panel dimensions are finite and positive')
    end
    panel.cancel(nil, 'control-removed')
    panel.surface.width, panel.surface.height = width, height
    panel.surface.pixelWidth, panel.surface.pixelHeight =
      logicalWidth or panel.surface.pixelWidth, logicalHeight or panel.surface.pixelHeight
    panel.revision += 1
  end
  function panel.surface.setPose(_, pose)
    handle:setPose(pose)
  end
  function panel.surface.setSize(_, width, height)
    local nextWidth = width or panel.surface.width
    handle:setSize(nextWidth, height or panel.surface.height * nextWidth / panel.surface.width)
  end
  function handle.setVisible(_: ui.Panel, value: boolean)
    if not panel.live() or panel.visible == value then
      return
    end
    panel.visible = value
    panel.revision += 1
    if not value then
      panel.cancel(nil, 'hidden')
      local ordered = table.clone(panel.controls)
      for index, control in ordered do
        if control.focused then
          table.remove(ordered, index)
          table.insert(ordered, 1, control)
          break
        end
      end
      for _, control in ordered do
        control.hovered = {}
        if control.target then
          control.target:blur()
        end
      end
    end
  end
  function handle.setTheme(_: ui.Panel, value: ui.ThemeOverrides?)
    if not panel.live() then
      return
    end
    local copied = appearance.copyOverrides(value)
    panel.overrides = copied
    panel.revision += 1
    panel.cancel(nil, 'control-removed')
  end
  function handle.describe(_: ui.Panel): ui.Description
    local described = {}
    for _, control in panel.controls do
      if control.live() then
        described[#described + 1] = table.freeze {
          id = control.id,
          owner = control.identity,
          kind = control.kind,
          label = control.label,
          enabled = control.enabled,
          bounds = geometry.intersect(control.bounds, panel.clip()),
          items = appearance.snapshotItems(items.rows(control)),
        }
      end
    end
    return table.freeze {
      name = panel.name,
      generation = provider.generation,
      revision = panel.revision,
      pose = table.freeze { panel.surface.pose:unpack(true) },
      width = panel.surface.width,
      height = panel.surface.height,
      logicalWidth = panel.surface.pixelWidth,
      logicalHeight = panel.surface.pixelHeight,
      visible = panel.live() and panel.visible,
      controls = table.freeze(described),
    }
  end
  function handle.draw(_: ui.Panel, pass: Pass)
    if not panel.live() or not panel.visible then
      return
    end
    local function render()
      pass:transform(panel.surface.pose)
      pass:translate(-panel.surface.width / 2, panel.surface.height / 2, 0)
      pass:scale(panel.surface.width / panel.surface.pixelWidth, -panel.surface.height / panel.surface.pixelHeight, 1)
      local function visual(control)
        local box = if control then control.bounds else panel.clip()
        local value, overflow = control and control.value, nil
        if control and (control.kind == 'choice' or control.kind == 'list') then
          local style = control.theme()
          local header = if control.kind == 'choice' then style.rowHeight + style.spacing else 0
          local content = math.max(0, #control.items * (style.rowHeight + style.spacing) - style.spacing)
          overflow = content > math.max(0, box.height - 2 * style.padding - header)
          if control.kind == 'choice' then
            for _, item in control.items do
              if item.id == control.chosen then
                value = item.label
              end
            end
          end
        end
        return {
          id = if control then control.id else panel.name,
          kind = if control then control.kind else 'panel',
          label = if control then control.label else panel.name,
          bounds = box,
          clip = geometry.intersect(box, panel.clip()),
          theme = if control then control.theme() else panel.theme(),
          enabled = not control or control.enabled,
          hovered = control ~= nil and next(control.hovered) ~= nil,
          pressed = control ~= nil and next(control.presses) ~= nil,
          focused = control ~= nil and control.focused == true,
          value = value,
          caret = control and control.caret,
          anchor = control and control.anchor,
          error = control and control.error,
          opened = control and control.opened,
          overflow = overflow,
          items = if control then items.rows(control) else {},
        }
      end
      local panelHooks = if panel.drawHook then { panel.drawHook } else {}
      appearance.paint(owner, pass, visual(nil), panelHooks)
      local ordered = table.clone(panel.controls)
      table.sort(ordered, function(a, b)
        return a.z < b.z
      end)
      for _, control in ordered do
        if control.live() and geometry.intersect(control.bounds, panel.clip()) then
          local hooks = table.clone(panelHooks)
          if control.drawHook then
            hooks[#hooks + 1] = control.drawHook
          end
          appearance.paint(control.owner, pass, visual(control), hooks)
        end
      end
    end
    protected.call('ui substitute ' .. plugin.ownerLabel(owner) .. ' panel draw', function()
      appearance.renderProtected(pass, render)
    end)
  end
  local effect
  local function dispose()
    if panel.dead then
      return
    end
    panel.dead, handle.dead, panel.surface.dead = true, true, true
    local failures = {}
    local ok, message = pcall(function()
      panel.cancel(nil, 'surface-dead')
    end)
    if not ok then
      failures[#failures + 1] = tostring(message)
    end
    local ordered = table.clone(panel.controls)
    for index, control in ordered do
      if control.focused then
        table.remove(ordered, index)
        table.insert(ordered, 1, control)
        break
      end
    end
    for _, control in ordered do
      ok, message = pcall(function()
        control.handle:destroy()
      end)
      if not ok then
        failures[#failures + 1] = tostring(message)
      end
    end
    panel.controls, panel.gestures, panel.drawHook = {}, {}, nil
    local index = table.find(provider.panels, panel)
    if index then
      table.remove(provider.panels, index)
    end
    if #failures > 0 then
      error(table.concat(failures, '\n'), 0)
    end
  end
  function handle.destroy(_: ui.Panel): boolean
    if panel.dead then
      return false
    end
    local release = effect
    effect = nil
    local cleaned, cleanup = pcall(dispose)
    local released, failure = pcall(function()
      if release then
        release:dispose()
      end
    end)
    if not cleaned then
      error(tostring(cleanup) .. (if released then '' else '\nresource release: ' .. tostring(failure)), 0)
    end
    if not released then
      error(failure, 0)
    end
    return true
  end
  function handle.button(_: ui.Panel, controlOwner: ui.Owner, value: ui.ButtonOptions): ui.Button
    return controls.new(panel, controlOwner, value, 'button')
  end
  function handle.textField(_: ui.Panel, controlOwner: ui.Owner, value: ui.TextFieldOptions): ui.TextField
    return controls.new(panel, controlOwner, value, 'text-field')
  end
  function handle.choice(_: ui.Panel, controlOwner: ui.Owner, value: ui.ChoiceOptions): ui.Choice
    return controls.new(panel, controlOwner, value, 'choice')
  end
  function handle.list(_: ui.Panel, controlOwner: ui.Owner, value: ui.ListOptions): ui.List
    return controls.new(panel, controlOwner, value, 'list')
  end
  function handle.region(_: ui.Panel, controlOwner: ui.Owner, value: ui.RegionOptions): ui.Region
    return controls.new(panel, controlOwner, value, 'region')
  end
  panel.handle = handle
  local _, acquired = provider.context:resource(owner, function()
    provider.panels[#provider.panels + 1] = panel
    return handle, dispose
  end)
  effect = acquired
  return handle
end

return panels
