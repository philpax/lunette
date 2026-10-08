local testing = require '@testing'
local textField = require '../../text-field'

local fixture = {}

function fixture.new(options)
  testing.native()
  local state = { live = true, changes = 0, focused = false, calls = {}, reports = {} }
  local bounds = { x = 10, y = 20, width = 200, height = 32 }
  local theme = {
    background = { 0, 0, 0, 1 },
    foreground = { 1, 1, 1, 1 },
    control = { 0, 0, 0, 1 },
    hovered = { 0, 0, 0, 1 },
    pressed = { 0, 0, 0, 1 },
    disabled = { 0, 0, 0, 1 },
    focus = { 1, 1, 1, 1 },
    selection = { 1, 1, 1, 1 },
    error = { 1, 0, 0, 1 },
    border = { 1, 1, 1, 1 },
    fontSize = 20,
    padding = 4,
    spacing = 4,
    borderWidth = 1,
    rowHeight = 24,
    hapticStrength = 0,
    hapticDuration = 0,
  }
  local widget
  local host = {
    live = function()
      return state.live
    end,
    interactive = function()
      return state.live
    end,
    captured = function()
      return state.live
    end,
    changed = function()
      state.changes += 1
    end,
    cancel = function(reason)
      state.calls[#state.calls + 1] = { 'cancel', reason }
    end,
    focus = function()
      if not state.live then
        return false
      end
      state.focused = true
      widget.onFocus(true)
      return true
    end,
    blur = function()
      if not state.live or not state.focused then
        return false
      end
      state.focused = false
      widget.onFocus(false)
      return true
    end,
    bounds = function()
      return bounds
    end,
    clip = function()
      return bounds
    end,
    theme = function()
      return theme
    end,
    withFont = function(run)
      run(lovr.graphics.getDefaultFont())
    end,
    callback = function(name, run)
      if not state.live then
        return false
      end
      state.calls[#state.calls + 1] = { name }
      local ok, message = pcall(run)
      if not ok then
        state.reports[#state.reports + 1] = { name = name, message = tostring(message) }
      end
      return ok
    end,
  }
  local supplied = table.clone(options or {})
  supplied.id = 'draft'
  supplied.bounds = bounds
  widget = textField.new(supplied, host)
  local field = table.clone(widget.methods)
  field.id = supplied.id
  field.dead = false
  local function snapshot()
    return widget.visual {
      id = field.id,
      kind = widget.kind,
      label = 'Draft',
      bounds = bounds,
      clip = bounds,
      theme = theme,
      enabled = true,
      hovered = false,
      pressed = false,
      focused = false,
      items = {},
    }
  end
  return {
    field = field,
    widget = widget,
    receiver = widget.receiver,
    state = state,
    snapshot = snapshot,
    theme = theme,
  }
end

function fixture.key(code, modifiers, source)
  return { code = code, modifiers = modifiers or {}, source = source or 'virtual', isRepeat = false }
end

function fixture.pointer(pointer, kind, x, button, captured)
  return { pointer = pointer, kind = kind, x = x, y = 25, inside = true, captured = captured or false, button = button }
end

return fixture
