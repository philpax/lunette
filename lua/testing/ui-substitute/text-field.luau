-- Single-line drafts and local focus receivers edit only native extended grapheme boundaries.

local lunette = require '@lunette'
local ui = require '@lunette-contracts/ui'
local appearance = require './appearance'

local textField = {}
local textBoundaries, snap

function textField.install(control)
  local handle, options, panel = control.handle, control.options, control.panel
  control.value = options.value or ''
  textBoundaries(control.value)
  control.caret, control.anchor = #control.value + 1, #control.value + 1
  control.revision = 0
  local function validate(revision)
    if not control.live() or control.revision ~= revision then
      return false
    end
    if not options.validate then
      return true
    end
    local value, message = control.value, nil
    local succeeded = appearance.callback(control, 'validate', function()
      message = options.validate(value)
      assert(message == nil or type(message) == 'string', 'text field: validate must return a string or nil')
    end)
    if not control.live() or control.revision ~= revision then
      return false
    end
    control.error = if succeeded then message else 'Validation failed.'
    return succeeded and control.live() and control.revision == revision
  end
  local function select(caret, anchor)
    if control.caret ~= caret or control.anchor ~= anchor then
      control.caret, control.anchor = caret, anchor
      control.revision += 1
    end
  end
  local function replace(value, caret, publish)
    textBoundaries(value)
    caret = snap(value, caret)
    if value == control.value and caret == control.caret and caret == control.anchor then
      return
    end
    local changed = value ~= control.value
    control.value, control.caret, control.anchor = value, caret, caret
    control.revision += 1
    local revision = control.revision
    if not changed then
      return
    end
    control.error = nil
    if not validate(revision) then
      return
    end
    if publish and options.onChange and control.live() and control.revision == revision then
      appearance.callback(control, 'onChange', function()
        options.onChange(value)
      end)
    end
  end
  local function insert(value)
    textBoundaries(value)
    local first, last = math.min(control.caret, control.anchor), math.max(control.caret, control.anchor)
    replace(control.value:sub(1, first - 1) .. value .. control.value:sub(last), first + #value, true)
  end
  function handle.setValue(_: ui.TextField, value: string)
    if control.live() then
      replace(value, #value + 1, false)
    end
  end
  function handle.value(_: ui.TextField): string
    return control.value
  end
  function handle.setSelection(_: ui.TextField, caret: number, anchor: number?)
    if not control.live() then
      return
    end
    local boundaries = textBoundaries(control.value)
    assert(
      table.find(boundaries, caret) and table.find(boundaries, anchor or caret),
      'text field: selection must name an extended grapheme boundary'
    )
    select(caret, anchor or caret)
  end
  function handle.selection(_: ui.TextField): (number, number)
    return control.caret, control.anchor
  end
  function handle.setError(_: ui.TextField, message: string?)
    if not control.live() then
      return
    end
    assert(message == nil or type(message) == 'string', 'text field: setError requires a string or nil')
    if control.error ~= message then
      control.revision += 1
      control.error = message
    end
  end
  function handle.focus(_: ui.TextField): boolean
    return control.live() and control.enabled and panel.visible and control.target:focus()
  end
  function handle.blur(_: ui.TextField): boolean
    return control.live() and control.target:blur()
  end
  local codes = lunette.keyCodes()
  control.receiver = {
    text = function(value)
      if not control.live() or not control.enabled or not panel.visible then
        return false
      end
      if value ~= '' then
        insert(value)
      end
      return true
    end,
    key = function(event)
      if not control.live() or not control.enabled or not panel.visible then
        return false
      end
      local shift, ctrl = false, false
      for _, modifier in event.modifiers do
        if modifier == 'shift' then
          shift = true
        elseif modifier == 'control' then
          ctrl = true
        else
          return false
        end
      end
      if ctrl then
        if event.code ~= codes.a then
          return false
        end
        select(#control.value + 1, 1)
        return true
      end
      local boundaries = textBoundaries(control.value)
      local index = table.find(boundaries, control.caret)
      if event.code == codes.backspace or event.code == codes.delete then
        if control.caret == control.anchor then
          control.anchor =
            boundaries[math.clamp(index + (if event.code == codes.backspace then -1 else 1), 1, #boundaries)]
        end
        insert ''
      elseif
        event.code == codes.left
        or event.code == codes.right
        or event.code == codes.home
        or event.code == codes['end']
      then
        local nextPosition
        if event.code == codes.home then
          nextPosition = 1
        elseif event.code == codes['end'] then
          nextPosition = #control.value + 1
        elseif not shift and control.caret ~= control.anchor then
          nextPosition = if event.code == codes.left
            then math.min(control.caret, control.anchor)
            else math.max(control.caret, control.anchor)
        else
          nextPosition = boundaries[math.clamp(index + (if event.code == codes.left then -1 else 1), 1, #boundaries)]
        end
        select(nextPosition, if shift then control.anchor else nextPosition)
      elseif event.code == codes.enter or event.code == codes.keypadEnter then
        local revision = control.revision
        if validate(revision) and not control.error and options.onSubmit and control.live() then
          local value = control.value
          appearance.callback(control, 'onSubmit', function()
            options.onSubmit(value)
          end)
        end
      elseif event.code == codes.escape then
        local revision, value, target = control.revision, control.value, control.target
        if target then
          target:blur()
        end
        if options.onCancel and control.live() and control.revision == revision then
          appearance.callback(control, 'onCancel', function()
            options.onCancel(value)
          end)
        end
      else
        return false
      end
      return true
    end,
  }
  validate(control.revision)
end

textBoundaries = function(value)
  local result = lunette.textBoundaries(value)
  for _, code in utf8.codes(value) do
    assert(
      code >= 32 and not (code >= 0x7f and code <= 0x9f) and code ~= 0x2028 and code ~= 0x2029,
      'text field: only single-line text is supported'
    )
  end
  return result
end

snap = function(value, position)
  for _, boundary in textBoundaries(value) do
    if boundary >= position then
      return boundary
    end
  end
  return #value + 1
end

return textField
