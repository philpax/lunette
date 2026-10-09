-- Control resources retain their widget and focus target until explicit disposal or owner teardown.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local records = require '@lunette-plugins/ui/panel-state'
local control = require '@lunette-plugins/ui/control'
local owners = require '@lunette-plugins/ui/control-owners'
local input = require '@lunette-plugins/ui/input'
local geometry = require '@lunette-plugins/ui/geometry'
local theme = require '@lunette-plugins/ui/theme'
local appearance = require './appearance'
local drawing = require './draw'
local protected = require '@lunette-plugins/protected'
local vocabulary = require '@lunette-contracts/vocabulary'

local handles = {}

type Factory = (control.Host) -> control.Widget

local function live(panel: records.Panel, record: records.Control): boolean
  return not panel.dead
    and not record.dead
    and panel.context:active()
    and panel.context:owns(panel.owner)
    and panel.context:owns(record.owner)
end

local function failAll(operations: { () -> () }): ()
  local failures: { string } = {}
  for _, operation in ipairs(operations) do
    local ok, failure = pcall(operation)
    if not ok then
      failures[#failures + 1] = tostring(failure)
    end
  end
  if #failures > 0 then
    error('ui: control cleanup: ' .. table.concat(failures, '; '), 0)
  end
end

function handles.create(panel: records.Panel, owner: ui.Owner, options: ui.Options, factory: Factory): ui.Control
  panel.context:checkOwner(owner)
  assert(type(options.id) == 'string' and options.id ~= '', 'ui: control id is a non-empty string')
  geometry.validateBounds(options.bounds)
  assert(options.enabled == nil or type(options.enabled) == 'boolean', 'ui: control enabled is a boolean')
  assert(options.exclusive == nil or type(options.exclusive) == 'boolean', 'ui: control exclusive is a boolean')
  assert(options.label == nil or type(options.label) == 'string', 'ui: control label is a string')
  assert(options.draw == nil or type(options.draw) == 'function', 'ui: control draw is a function')
  local z = options.z or 0
  assert(type(z) == 'number' and z == z and math.abs(z) < math.huge, 'ui: control z is finite')
  local id = options.id
  local bounds = table.freeze(table.clone(options.bounds))
  local label = options.label or ''
  local enabled = options.enabled ~= false
  local exclusive = options.exclusive ~= false
  local draw = options.draw
  local overrides = theme.copyOverrides(options.theme)
  panel.refresh()
  local spec = theme.inherit(panel.spec, overrides)
  local reservation = owners.reserve(panel.owners, panel.context, owner, id)
  local acquired, lease = pcall(panel.themes.acquireFont, panel.themes, panel.context, spec.font)
  if not acquired then
    reservation.release()
    error(lease, 0)
  end
  local prepared, resolved = pcall(theme.materialize, spec, lease.font)
  if not prepared then
    reservation.release()
    local released, failure = pcall(lease.dispose, lease)
    error(tostring(resolved) .. (if released then '' else '; ' .. tostring(failure)), 0)
  end
  local callbackLabel = 'ui: ' .. plugin.ownerLabel(owner) .. ': control ' .. id
  local record: records.Control
  local initializing, abandoned = true, false
  local target: focus.TargetHandle? = nil
  local release: plugin.Effect? = nil
  local function current(): boolean
    if abandoned then
      return false
    elseif initializing then
      return not panel.dead and panel.context:active() and panel.context:owns(panel.owner) and panel.context:owns(owner)
    end
    return live(panel, record)
  end
  local function interactive(): boolean
    return current() and panel.visible and not panel.cancelling and (if initializing then enabled else record.enabled)
  end
  local function dispose(): boolean
    if initializing then
      abandoned = true
      lease:dispose()
      reservation.release()
      return false
    elseif record.dead then
      return false
    end
    record.dead, record.focused = true, false
    reservation.release()
    local index = table.find(panel.controls, record)
    if index then
      table.remove(panel.controls, index)
    end
    panel.revision += 1
    local old, inverse = target, release
    target, record.target, release = nil, nil, nil
    failAll {
      function(): ()
        drawing.clearCache(record.measurements)
      end,
      function(): ()
        if record.widget.clearMeasurements then
          record.widget.clearMeasurements()
        end
      end,
      function(): ()
        record.lease:dispose()
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
    }
    return true
  end
  local function receiverCall(name: string, run: () -> boolean): boolean
    local ok, result = pcall(run)
    if not ok then
      error(callbackLabel .. ': ' .. name .. ': ' .. tostring(result), 0)
    end
    return result
  end
  local host: control.Host = {
    live = current,
    interactive = interactive,
    captured = function(pointer: vocabulary.Pointer, button): boolean
      if initializing or not interactive() then
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
      if not initializing and current() then
        input.cancel(panel, record, reason)
      end
    end,
    focus = function(): boolean
      return not initializing and interactive() and target ~= nil and not target.dead and target:focus()
    end,
    blur = function(): boolean
      return current() and target ~= nil and not target.dead and target:blur()
    end,
    bounds = function(): ui.Bounds
      return if initializing then bounds else record.bounds
    end,
    clip = function(): ui.Bounds?
      if initializing then
        return geometry.intersect(bounds, {
          x = 0,
          y = 0,
          width = panel.logicalWidth,
          height = panel.logicalHeight,
        })
      end
      return input.bounds(panel, record)
    end,
    textClip = function(): ui.Bounds?
      return if panel.contour and not initializing then input.bounds(panel, record) else nil
    end,
    theme = function(): ui.Theme
      panel.refresh()
      return if initializing then resolved else record.theme
    end,
    withFont = function(run: (Font) -> ()): ()
      panel.refresh()
      local currentLease = if initializing then lease else record.lease
      currentLease:withFont(run)
    end,
    callback = function(name: string, run: () -> (), terminal: boolean?): boolean
      local allowed = if terminal then (owner :: plugin.Context):active() else current()
      return allowed and protected.call(callbackLabel .. ': ' .. name, run)
    end,
  }
  local ok, result = pcall(function(): ui.Control
    local widget = factory(host)
    assert(current(), 'ui: control owner ended during initialization')
    panel.nextOrder += 1
    local initialized: records.Control = {
      dead = false,
      id = id,
      owner = owner,
      identity = reservation.identity,
      dispose = dispose,
      kind = widget.kind,
      label = label,
      bounds = bounds,
      enabled = enabled,
      z = z,
      order = panel.nextOrder,
      exclusive = exclusive,
      theme = resolved,
      spec = spec,
      lease = lease,
      measurements = drawing.newCache(),
      overrides = overrides,
      draw = draw,
      widget = widget,
      target = nil,
      focused = false,
    }
    record = initialized
    initializing = false
    local base: ui.Control = {
      dead = false,
      id = record.id,
      owner = record.identity,
      setBounds = function(_self: ui.Control, given: ui.Bounds): ()
        if not live(panel, record) then
          return
        end
        geometry.validateBounds(given)
        record.bounds = table.freeze(table.clone(given))
        drawing.clearCache(record.measurements)
        panel.revision += 1
        input.cancel(panel, record, 'control-removed')
      end,
      setEnabled = function(_self: ui.Control, given: boolean): ()
        if not live(panel, record) then
          return
        end
        assert(type(given) == 'boolean', 'ui: control enabled is a boolean')
        if record.enabled == given then
          return
        end
        record.enabled = given
        panel.revision += 1
        if not given then
          failAll {
            function(): ()
              input.cancel(panel, record, 'disabled')
            end,
            function(): ()
              if target and not target.dead then
                target:blur()
              end
            end,
          }
        end
      end,
      setTheme = function(_self: ui.Control, given: ui.ThemeOverrides?): ()
        if not live(panel, record) then
          return
        end
        appearance.control(panel, record, given)
      end,
      destroy = function(_self: ui.Control): boolean
        return dispose()
      end,
    }
    local methods: { [string]: unknown } = {
      setBounds = base.setBounds,
      setEnabled = base.setEnabled,
      setTheme = base.setTheme,
      destroy = base.destroy,
    }
    for name, method in widget.methods do
      methods[name] = method
    end
    -- The checked base and widget methods supply the dynamic handle; its fields come from the retained record.
    local handle: ui.Control = table.freeze(setmetatable({}, {
      __index = function(_self: unknown, key: string): unknown
        if key == 'dead' then
          return not current()
        elseif key == 'id' then
          return record.id
        elseif key == 'owner' then
          return record.identity
        end
        return methods[key]
      end,
      __newindex = function(): ()
        error('ui: a control is read-only', 2)
      end,
    })) :: ui.Control
    if widget.receiver then
      local receiver = widget.receiver
      target = panel.focus:register(panel.context, {
        kind = 'local',
        wantsKeyboard = widget.wantsKeyboard,
        keymapSeat = widget.keymapSeat,
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
    assert(current(), 'ui: control owner ended during focus registration')
    release = panel.context:acquire(owner, function(): () -> ()
      return function(): ()
        release = nil
        dispose()
      end
    end)
    assert(current(), 'ui: control owner ended during acquisition')
    panel.controls[#panel.controls + 1] = record
    panel.revision += 1
    return handle
  end)
  if not ok then
    local clean, failure = pcall(dispose)
    if not clean then
      error(tostring(result) .. '; ' .. tostring(failure), 0)
    end
    error(result, 0)
  end
  return result
end

return handles
