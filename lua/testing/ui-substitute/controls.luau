-- Acquires owner-scoped controls and releases focus targets with retained dead handles.

local ui = require '@lunette-contracts/ui'
local appearance = require './appearance'
local geometry = require './geometry'
local items = require './items'
local textField = require './text-field'

local controls = {}
local installRegion, snapshot

function controls.new(panel, owner, input, kind)
  local provider = panel.provider
  provider.context:checkOwner(owner)
  assert(panel.live(), 'ui substitute: the panel is dead')
  local options = snapshot(input, kind)
  assert(type(options.id) == 'string' and options.id ~= '', 'ui substitute: control id is nonempty')
  local control = {
    dead = false,
    id = options.id,
    panel = panel,
    owner = owner,
    kind = kind,
    bounds = options.bounds,
    enabled = options.enabled ~= false,
    label = options.label or '',
    overrides = options.theme,
    drawHook = options.draw,
    z = options.z or 0,
    exclusive = options.exclusive ~= false,
    items = {},
    offset = 0,
    opened = false,
    hovered = {},
    presses = {},
    options = options,
  }
  local handle = { dead = false, id = options.id }
  control.handle = handle
  function control.live()
    return not control.dead and panel.live() and provider.context:owns(owner)
  end
  function control.theme()
    return appearance.theme(panel.theme(), control.overrides)
  end
  function control.changed(reason)
    panel.revision += 1
    panel.cancel(control, reason or 'control-removed')
  end
  function handle.setBounds(_: ui.Control, value: ui.Bounds)
    if not control.live() then
      return
    end
    control.bounds = geometry.bounds(value)
    control.changed()
  end
  function handle.setEnabled(_: ui.Control, value: boolean)
    if not control.live() or control.enabled == value then
      return
    end
    control.enabled = value
    control.changed(if value then 'control-removed' else 'disabled')
    if not value and control.target then
      control.target:blur()
    end
  end
  function handle.setTheme(_: ui.Control, value: ui.ThemeOverrides?)
    if not control.live() then
      return
    end
    control.overrides = appearance.copyOverrides(value)
    control.changed()
  end
  local effect, releaseId
  local function dispose()
    if control.dead then
      return
    end
    control.dead, handle.dead = true, true
    local target = control.target
    control.target = nil
    local cancelled, cancellation = pcall(function()
      control.changed 'control-removed'
    end)
    local blurred, blur = pcall(function()
      if target and provider.context:owns(owner) then
        target:blur()
      end
    end)
    local destroyed, destruction = pcall(function()
      if target then
        target:destroy()
      end
    end)
    if releaseId then
      releaseId()
      releaseId = nil
    end
    local index = table.find(panel.controls, control)
    if index then
      table.remove(panel.controls, index)
    end
    control.hovered, control.presses, control.receiver = {}, {}, nil
    control.options, control.drawHook = {}, nil
    if not cancelled then
      error(cancellation, 0)
    end
    if not blurred then
      error(blur, 0)
    end
    if not destroyed then
      error(destruction, 0)
    end
  end
  function handle.destroy(_: ui.Control): boolean
    if control.dead then
      return false
    end
    -- Deliberate destruction delivers terminals before the resource inverse enters cleanup authority.
    local cleaned, cleanup = pcall(dispose)
    local released, release = pcall(function()
      if effect then
        effect:dispose()
      end
    end)
    if not cleaned then
      error(tostring(cleanup) .. (if released then '' else '\nresource release: ' .. tostring(release)), 0)
    end
    if not released then
      error(release, 0)
    end
    return true
  end
  local _, acquired = provider.context:resource(owner, function()
    local ok, message = pcall(function()
      control.identity, releaseId = provider.owners.claim(owner, options.id, control)
      handle.owner = control.identity
      if kind == 'text-field' then
        textField.install(control)
      elseif kind == 'choice' or kind == 'list' then
        items.install(control)
      elseif kind == 'region' then
        installRegion(control)
      end
      assert(control.live(), 'ui substitute: the control owner or panel ended during acquisition')
      if control.receiver then
        local receiver = control.receiver
        local onFocus, onBlur = receiver.onFocus, receiver.onBlur
        receiver.onFocus = function(change)
          control.focused = true
          if onFocus then
            onFocus(change)
          end
        end
        receiver.onBlur = function(change)
          control.focused = false
          if onBlur then
            onBlur(change)
          end
        end
        control.target = provider.focus:register(provider.context, {
          kind = 'local',
          receiver = control.receiver,
          keymapSeat = options.keymapSeat,
          wantsKeyboard = kind == 'text-field' or options.wantsKeyboard == true,
        })
      end
      panel.controls[#panel.controls + 1] = control
      panel.revision += 1
    end)
    if not ok then
      local cleaned, cleanup = pcall(dispose)
      if not cleaned then
        message = tostring(message) .. '\ncontrol cleanup: ' .. tostring(cleanup)
      end
      error(message, 0)
    end
    return handle, dispose
  end)
  effect = acquired
  return handle
end

installRegion = function(control)
  local options, handle, panel = control.options, control.handle, control.panel
  control.items = options.items or {}
  if options.receiver then
    local receiver = options.receiver
    control.receiver = {}
    for _, method in { 'key', 'text', 'onFocus', 'onBlur' } do
      local run = receiver[method]
      if run then
        control.receiver[method] = function(event)
          if not panel.provider.context:owns(control.owner) then
            return false
          end
          if
            (method == 'key' or method == 'text')
            and (not control.live() or not control.enabled or not panel.visible)
          then
            return false
          end
          return appearance.focusCallback(control, method, function()
            return run(event)
          end)
        end
      end
    end
  end
  function handle.setItems(_: ui.Region, values: { ui.RegionItem })
    if control.live() then
      local replacement = items.copy(values, true)
      control.items = replacement
      control.changed()
    end
  end
end

snapshot = function(input, kind)
  local result = {
    id = input.id,
    bounds = geometry.bounds(input.bounds),
    label = input.label,
    enabled = input.enabled,
    z = input.z,
    theme = appearance.copyOverrides(input.theme),
    draw = input.draw,
    exclusive = input.exclusive,
    onActivate = input.onActivate,
    value = input.value,
    onChange = input.onChange,
    onSubmit = input.onSubmit,
    onCancel = input.onCancel,
    validate = input.validate,
    keymapSeat = input.keymapSeat,
    selected = input.selected,
    onPointer = input.onPointer,
    wantsKeyboard = input.wantsKeyboard,
  }
  if input.items then
    result.items = items.copy(input.items, kind == 'region')
  end
  if input.receiver then
    result.receiver = table.freeze {
      key = input.receiver.key,
      text = input.receiver.text,
      onFocus = input.receiver.onFocus,
      onBlur = input.receiver.onBlur,
    }
  end
  return table.freeze(result)
end

return controls
