-- A panel-owned text field delegates focus routing and protected callbacks to its private host.
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local surface = require '@lunette-contracts/surface'
local keys = require '@lunette-contracts/keys'
local control = require './control'
local edit = require './text-edit'
local measurement = require './measurement-cache'
local textGeometry = require './text-field-geometry'
local validation = require './validation'

local textField = {}

local validate: (State, number) -> boolean
local apply: (State, edit.State, boolean) -> ()
local setError: (State, string?) -> ()
local key: (State, focus.KeyEvent) -> boolean
local pointer: (State, surface.PointerEvent) -> ()
local pointerCaret: (State, number) -> number?
local visual: (State, ui.Visual) -> ui.Visual
local hasModifier: (focus.KeyEvent, string) -> boolean

type State = {
  host: control.Host,
  measurements: measurement.Cache,
  options: ui.TextFieldOptions,
  draft: edit.State,
  revision: number,
  error: string?,
  focused: boolean,
  dragging: surface.Pointer?,
}

function textField.new(options: ui.TextFieldOptions, host: control.Host): control.Widget
  options = validation.textField(options)
  local state: State = {
    host = host,
    measurements = measurement.new(),
    options = options,
    draft = edit.new(if options.value == nil then '' else options.value),
    revision = 0,
    error = nil,
    focused = false,
    dragging = nil,
  }
  validate(state, state.revision)
  local methods = {
    setValue = function(_self: ui.TextField, value: string): ()
      if host.live() then
        apply(state, edit.new(value), false)
      end
    end,
    value = function(_self: ui.TextField): string
      return state.draft.value
    end,
    setSelection = function(_self: ui.TextField, caret: number, anchor: number?): ()
      if host.live() then
        apply(state, edit.select(state.draft, caret, anchor), false)
      end
    end,
    selection = function(_self: ui.TextField): (number, number)
      return state.draft.caret, state.draft.anchor
    end,
    setError = function(_self: ui.TextField, message: string?): ()
      if not host.live() then
        return
      end
      assert(message == nil or type(message) == 'string', 'ui text field setError: a string or nil is required')
      if state.error ~= message then
        state.revision += 1
        setError(state, message)
      end
    end,
    focus = function(_self: ui.TextField): boolean
      return host.live() and host.focus()
    end,
    blur = function(_self: ui.TextField): boolean
      return host.live() and host.blur()
    end,
  }
  local receiver: focus.Receiver = {
    key = function(event: focus.KeyEvent): boolean
      return key(state, event)
    end,
    text = function(text: string): boolean
      if not host.live() then
        return false
      end
      if text ~= '' then
        apply(state, edit.insert(state.draft, text), true)
      end
      return true
    end,
  }
  return {
    kind = 'text-field',
    methods = methods,
    receiver = receiver,
    keymapSeat = options.keymapSeat,
    wantsKeyboard = true,
    onFocus = function(focused: boolean): ()
      if focused and not host.live() then
        return
      end
      if not focused then
        state.dragging = nil
      end
      if state.focused ~= focused then
        state.focused = focused
        host.changed()
      end
    end,
    pointer = function(event: surface.PointerEvent, _itemId: string?): ()
      pointer(state, event)
    end,
    items = function(_bounds: ui.Bounds, _theme: ui.Theme): { ui.ItemDescription }
      return {}
    end,
    visual = function(base: ui.Visual): ui.Visual
      return visual(state, base)
    end,
    clearMeasurements = function(): ()
      measurement.clear(state.measurements)
    end,
  }
end

validate = function(state: State, revision: number): boolean
  local validator = state.options.validate
  if not validator then
    return state.host.live() and state.revision == revision
  end
  local message: string? = nil
  local value = state.draft.value
  local succeeded = state.host.callback('validate', function(): ()
    message = validator(value)
    if message ~= nil and type(message) ~= 'string' then
      error 'text field: validate must return a string or nil'
    end
  end)
  if not state.host.live() or state.revision ~= revision then
    return false
  end
  setError(state, if succeeded then message else 'Validation failed.')
  return succeeded and state.host.live() and state.revision == revision
end

apply = function(state: State, draft: edit.State, notify: boolean): ()
  local previous = state.draft
  if draft.value == previous.value and draft.caret == previous.caret and draft.anchor == previous.anchor then
    return
  end
  local changedValue = draft.value ~= previous.value
  state.draft = draft
  state.revision += 1
  local revision = state.revision
  if changedValue then
    state.error = nil
  end
  state.host.changed()
  if not state.host.live() or state.revision ~= revision or not changedValue then
    return
  end
  if not validate(state, revision) then
    return
  end
  local callback = state.options.onChange
  if notify and callback and state.host.live() and state.revision == revision then
    state.host.callback('onChange', function(): ()
      callback(draft.value)
    end)
  end
end

setError = function(state: State, message: string?): ()
  if state.error ~= message then
    state.error = message
    state.host.changed()
  end
end

key = function(state: State, event: focus.KeyEvent): boolean
  if not state.host.live() then
    return false
  end
  local codes = keys.CODES
  local shift, ctrl = hasModifier(event, 'shift'), hasModifier(event, 'control')
  if hasModifier(event, 'alt') or hasModifier(event, 'logo') or hasModifier(event, 'mod5') then
    return false
  end
  if ctrl then
    if event.code == codes.a then
      apply(state, edit.select(state.draft, #state.draft.value + 1, 1), false)
      return true
    end
    return false
  end
  if event.code == codes.left then
    apply(state, edit.move(state.draft, 'left', shift), false)
  elseif event.code == codes.right then
    apply(state, edit.move(state.draft, 'right', shift), false)
  elseif event.code == codes.home then
    apply(state, edit.move(state.draft, 'home', shift), false)
  elseif event.code == codes['end'] then
    apply(state, edit.move(state.draft, 'end', shift), false)
  elseif event.code == codes.backspace or event.code == codes.delete then
    apply(state, edit.erase(state.draft, if event.code == codes.backspace then 'backward' else 'forward'), true)
  elseif event.code == codes.enter or event.code == codes.keypadEnter then
    local revision = state.revision
    if validate(state, revision) and state.error == nil then
      local callback = state.options.onSubmit
      if callback and state.host.live() and state.revision == revision then
        local value = state.draft.value
        state.host.callback('onSubmit', function(): ()
          callback(value)
        end)
      end
    end
  elseif event.code == codes.escape then
    state.dragging = nil
    local revision, value = state.revision, state.draft.value
    state.host.blur()
    local callback = state.options.onCancel
    if callback and state.host.live() and state.revision == revision then
      state.host.callback('onCancel', function(): ()
        callback(value)
      end)
    end
  else
    return false
  end
  return true
end

pointer = function(state: State, event: surface.PointerEvent): ()
  if not state.host.live() then
    return
  end
  if event.kind == 'press' then
    if event.button ~= 'left' or not event.inside or event.x == nil or state.dragging ~= nil then
      return
    end
    local caret = pointerCaret(state, event.x)
    if caret == nil then
      return
    end
    apply(state, edit.select(state.draft, caret), false)
    if state.host.live() and event.captured then
      state.dragging = event.pointer
    end
    if not state.host.live() or not state.host.focus() then
      state.dragging = nil
      return
    end
    if not state.host.live() then
      state.dragging = nil
    end
  elseif event.kind == 'move' then
    if event.captured and event.button == 'left' and state.dragging == event.pointer and event.x ~= nil then
      local caret = pointerCaret(state, event.x)
      if caret ~= nil then
        apply(state, edit.select(state.draft, caret, state.draft.anchor), false)
      end
    end
  elseif event.kind == 'release' then
    if event.button == 'left' and state.dragging == event.pointer then
      state.dragging = nil
      if event.captured and event.x ~= nil then
        local caret = pointerCaret(state, event.x)
        if caret ~= nil then
          apply(state, edit.select(state.draft, caret, state.draft.anchor), false)
        end
      end
    end
  elseif event.kind == 'cancel' then
    if event.button == 'left' and state.dragging == event.pointer then
      state.dragging = nil
    end
  end
end

pointerCaret = function(state: State, x: number): number?
  local clip = state.host.clip()
  if not clip then
    return nil
  end
  local nearest: number? = nil
  state.host.withFont(function(font: Font): ()
    local layout = textGeometry.layout(
      state.draft.value,
      state.draft.caret,
      state.draft.anchor,
      state.host.bounds(),
      clip,
      state.host.theme(),
      font,
      state.measurements,
      if state.host.textClip then state.host.textClip() else nil
    )
    nearest = if layout then textGeometry.nearest(layout, x) else nil
  end)
  return nearest
end

visual = function(state: State, base: ui.Visual): ui.Visual
  return {
    id = base.id,
    kind = base.kind,
    label = base.label,
    bounds = base.bounds,
    clip = base.clip,
    theme = base.theme,
    enabled = base.enabled,
    hovered = base.hovered,
    pressed = base.pressed,
    focused = state.focused,
    value = state.draft.value,
    caret = state.draft.caret,
    anchor = state.draft.anchor,
    error = state.error,
    items = base.items,
  }
end

hasModifier = function(event: focus.KeyEvent, modifier: string): boolean
  for _, candidate in event.modifiers do
    if candidate == modifier then
      return true
    end
  end
  return false
end

return textField
