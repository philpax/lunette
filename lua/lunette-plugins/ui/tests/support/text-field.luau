local testing = require '@testing'
local textField = require '../../text-field'
local themes = require '../../theme'
local measurement = require '../../measurement-cache'

local fixture = {}

function fixture.new(options)
  testing.native()
  local state = { changes = 0, focused = false }
  local bounds = { x = 10, y = 20, width = 200, height = 32 }
  local theme = themes.materialize(
    themes.inherit(themes.DEFAULT, themes.copyOverrides { fontSize = 20, padding = 4 }),
    lovr.graphics.getDefaultFont()
  )
  local widget
  local measurements = measurement.new()
  local host = {
    live = function()
      return true
    end,
    interactive = function()
      return true
    end,
    captured = function()
      return true
    end,
    changed = function()
      state.changes += 1
    end,
    cancel = function() end,
    focus = function()
      state.focused = true
      widget.onFocus(true)
      return true
    end,
    blur = function()
      if not state.focused then
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
    textMeasurements = function()
      return measurements
    end,
    callback = function(_, run)
      run()
      return true
    end,
  }
  local supplied = table.clone(options or {})
  supplied.id = 'draft'
  supplied.bounds = bounds
  widget = textField.new(supplied, host)
  local function snapshot()
    return widget.visual {
      id = 'draft',
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
    field = widget.methods,
    widget = widget,
    receiver = widget.receiver,
    state = state,
    snapshot = snapshot,
  }
end

function fixture.key(code, modifiers, source)
  return { code = code, modifiers = modifiers or {}, source = source or 'virtual', isRepeat = false }
end

function fixture.pointer(pointer, kind, x, button)
  return { pointer = pointer, kind = kind, x = x, y = 25, inside = true, captured = true, button = button }
end

return fixture
