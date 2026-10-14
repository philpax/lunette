-- Control resources retain their widget and focus target until explicit disposal or owner teardown.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local records = require '@lunette-plugins/ui/panel-state'
local owners = require '@lunette-plugins/ui/control-owners'
local input = require '@lunette-plugins/ui/input'
local geometry = require '@lunette-plugins/ui/geometry'
local theme = require '@lunette-plugins/ui/theme'
local appearance = require './appearance'
local drawing = require './draw'
local measurement = require './measurement-cache'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'
local protected = require '@lunette-plugins/diagnostics/protected-call'
local vocabulary = require '@lunette-contracts/vocabulary'

local handles = {}
type PointerButton = typeof(vocabulary.POINTER_BUTTONS[1])

type Factory = (records.Host) -> records.Widget

-- The record exists before its factory runs, so the factory's host calls see the record's own state.
local PENDING: records.Widget = table.freeze {
  methods = {},
  wantsKeyboard = false,
  pointer = function(_event: vocabulary.PointerEvent, _item: string?): () end,
  items = function(_bounds: ui.Bounds, _theme: ui.Theme): { read [number]: ui.ItemDescription }
    return {}
  end,
  visual = function(value: ui.Visual): ui.Visual
    return value
  end,
}

local function live(panel: records.Panel, record: records.Control): boolean
  return not panel.dead
    and not record.dead
    and panel.context:active()
    and panel.context:owns(panel.owner)
    and panel.context:owns(record.owner)
end

-- Options arrive validated by the panel method that creates the control.
function handles.create(
  panel: records.Panel,
  owner: ui.Owner,
  kind: ui.Kind,
  options: ui.Options,
  factory: Factory
): ui.Control
  panel.context:checkOwner(owner)
  local id = options.id
  panel.refresh()
  local spec = theme.inherit(panel.spec, options.theme)
  local resolved = theme.materialize(spec, panel.themes:font(spec.font))
  local reservation = owners.reserve(panel.owners, panel.context, owner, id)
  local callbackLabel = 'ui: ' .. plugin.ownerLabel(owner) .. ': control ' .. id
  local target: focus.TargetHandle? = nil
  local release: plugin.Effect? = nil
  local handle: { [string]: unknown } = { dead = false, id = id, owner = reservation.identity }
  local record: records.Control
  local function dispose(): boolean
    if record.dead then
      return false
    end
    record.dead, record.focused = true, false
    handle.dead = true
    reservation.release()
    local index = table.find(panel.controls, record)
    if index then
      table.remove(panel.controls, index)
    end
    panel.revision += 1
    local old, inverse = target, release
    target, record.target, release = nil, nil, nil
    cleanup.run('ui: control cleanup', {
      function(): ()
        drawing.clearCache(record.measurements)
      end,
      function(): ()
        input.cancel(panel, record, 'control-removed')
      end,
      function(): ()
        if old and not old.dead then
          old:destroy()
        end
      end,
      function(): ()
        if inverse then
          inverse:dispose()
        end
      end,
    })
    return true
  end
  panel.nextOrder += 1
  local created: records.Control = {
    dead = false,
    id = id,
    owner = owner,
    identity = reservation.identity,
    dispose = dispose,
    kind = kind,
    label = options.label or '',
    bounds = options.bounds,
    enabled = options.enabled ~= false,
    z = options.z or 0,
    order = panel.nextOrder,
    theme = resolved,
    spec = spec,
    measurements = drawing.newCache(),
    overrides = options.theme,
    draw = options.draw,
    widget = PENDING,
    target = nil,
    focused = false,
  }
  record = created
  local function current(): boolean
    return live(panel, record)
  end
  local function interactive(): boolean
    return current() and panel.visible and not panel.cancelling and record.enabled
  end
  local function receiverCall(name: string, run: () -> boolean): boolean
    local ok, result = pcall(run)
    if not ok then
      error(callbackLabel .. ': ' .. name .. ': ' .. tostring(result), 0)
    end
    return result
  end
  local host: records.Host = {
    live = current,
    interactive = interactive,
    captured = function(pointer: vocabulary.Pointer, button: PointerButton): boolean
      if not interactive() then
        return false
      end
      local captures = panel.captures[pointer]
      local capture = captures and captures[button]
      return capture ~= nil and capture.control == record
    end,
    changed = function(): ()
      if current() then
        panel.revision += 1
      end
    end,
    cancel = function(reason: vocabulary.CancelReason): ()
      if current() then
        input.cancel(panel, record, reason)
      end
    end,
    focus = function(): boolean
      return interactive() and target ~= nil and not target.dead and target:focus()
    end,
    blur = function(): boolean
      return current() and target ~= nil and not target.dead and target:blur()
    end,
    bounds = function(): ui.Bounds
      return record.bounds
    end,
    clip = function(): ui.Bounds?
      return input.bounds(panel, record)
    end,
    textClip = function(): ui.Bounds?
      return if panel.contour then input.bounds(panel, record) else nil
    end,
    theme = function(): ui.Theme
      panel.refresh()
      return record.theme
    end,
    textMeasurements = function(): measurement.Cache
      return record.measurements.fields
    end,
    callback = function(name: string, run: () -> (), terminal: boolean?): boolean
      local allowed = if terminal then (owner :: plugin.Context):active() else current()
      return allowed and protected.call(callbackLabel .. ': ' .. name, run)
    end,
  }
  local methods: { [string]: unknown } = {
    setBounds = function(_self: ui.Control, given: ui.Bounds): ()
      if not current() then
        return
      end
      record.bounds = table.freeze(table.clone(geometry.validateBounds(given)))
      drawing.clearCache(record.measurements)
      panel.revision += 1
      input.cancel(panel, record, 'control-removed')
    end,
    setEnabled = function(_self: ui.Control, given: boolean): ()
      if not current() then
        return
      end
      assert(type(given) == 'boolean', 'ui: control enabled is a boolean')
      if record.enabled == given then
        return
      end
      record.enabled = given
      panel.revision += 1
      if not given then
        cleanup.run('ui: control cleanup', {
          function(): ()
            input.cancel(panel, record, 'disabled')
          end,
          function(): ()
            if target and not target.dead then
              target:blur()
            end
          end,
        })
      end
    end,
    setTheme = function(_self: ui.Control, given: ui.ThemeOverrides?): ()
      if current() then
        appearance.control(panel, record, given)
      end
    end,
    destroy = function(_self: ui.Control): boolean
      return dispose()
    end,
  }
  for name, method in methods do
    handle[name] = method
  end
  local ok, failure = pcall(function(): ()
    local widget = factory(host)
    record.widget = widget
    for name, method in widget.methods do
      handle[name] = method
    end
    if widget.receiver then
      local receiver = widget.receiver
      target = panel.focus:register(panel.context, {
        kind = 'local',
        wantsKeyboard = widget.wantsKeyboard,
        receiver = {
          key = function(event: focus.KeyEvent): boolean
            return interactive()
              and receiverCall('key', function(): boolean
                return receiver.key(event)
              end)
          end,
          text = function(text: string): boolean
            return interactive()
              and receiverCall('text', function(): boolean
                return receiver.text(text)
              end)
          end,
          onFocus = function(change: focus.Change): ()
            if not interactive() then
              return
            end
            record.focused = true
            local widgetFocus, onFocus = widget.onFocus, receiver.onFocus
            if widgetFocus then
              receiverCall('focus', function(): boolean
                widgetFocus(true)
                return true
              end)
            end
            if interactive() and record.focused and onFocus then
              receiverCall('focus', function(): boolean
                onFocus(change)
                return true
              end)
            end
          end,
          onBlur = function(change: focus.Change): ()
            if not current() or not record.focused then
              return
            end
            record.focused = false
            local widgetFocus, onBlur = widget.onFocus, receiver.onBlur
            if widgetFocus then
              receiverCall('blur', function(): boolean
                widgetFocus(false)
                return true
              end)
            end
            if current() and not record.focused and onBlur then
              receiverCall('blur', function(): boolean
                onBlur(change)
                return true
              end)
            end
          end,
        },
      })
      record.target = target
    end
    release = panel.context:acquire(owner, function(): () -> ()
      return function(): ()
        release = nil
        dispose()
      end
    end)
  end)
  if not ok then
    local clean, cleanupFailure = pcall(dispose)
    error(tostring(failure) .. (if clean then '' else '; ' .. tostring(cleanupFailure)), 0)
  end
  panel.controls[#panel.controls + 1] = record
  panel.revision += 1
  return (handle :: unknown) :: ui.Control
end

return handles
