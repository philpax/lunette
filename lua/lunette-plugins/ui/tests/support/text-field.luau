local testing = require '@testing'
local textField = require '../../text-field'
local themes = require '../../theme'
local measurement = require '../../measurement-cache'

type Bounds = themes.Bounds
type ItemDescription = themes.ItemDescription
type Receiver = textField.Receiver
type KeyEvent = textField.KeyEvent
type PointerButton = testing.PointerButton
type ModifierName = testing.ModifierName
type Font = testing.Font

type Options = {
  value: string?,
  onChange: ((string) -> ())?,
  onSubmit: ((string) -> ())?,
  onCancel: ((string) -> ())?,
  id: string?,
  bounds: Bounds?,
}
type Methods = {
  value: (Methods) -> string,
  setValue: (Methods, string) -> (),
  setError: (Methods, string?) -> (),
  focus: (Methods) -> boolean,
  blur: (Methods) -> boolean,
}
type Theme = themes.Theme<Font>
type Visual = {
  id: string,
  kind: 'text-field'?,
  label: string,
  bounds: Bounds,
  clip: Bounds,
  theme: Theme,
  enabled: boolean,
  hovered: boolean,
  pressed: boolean,
  focused: boolean,
  items: { ItemDescription },
  caret: number?,
  anchor: number?,
  value: string?,
  error: string?,
}
type PointerEvent<P> = {
  pointer: P,
  kind: 'press' | 'move' | 'release',
  x: number,
  y: number,
  inside: boolean,
  captured: boolean,
  button: PointerButton?,
}
type Widget = {
  methods: Methods,
  kind: 'text-field'?,
  receiver: Receiver,
  wantsKeyboard: boolean,
  onFocus: (boolean) -> (),
  pointer: <P>(PointerEvent<P>) -> (),
  visual: (Visual) -> Visual,
}
export type Fixture = {
  field: Methods,
  widget: Widget,
  receiver: Receiver,
  state: { changes: number, focused: boolean },
  snapshot: () -> Visual,
}

local fixture = {}

function fixture.new(options: Options?): Fixture
  testing.native()
  local state = { changes = 0, focused = false }
  local bounds = { x = 10, y = 20, width = 200, height = 32 }
  local theme = themes.materialize(
    themes.inherit(themes.DEFAULT, themes.copyOverrides { fontSize = 20, padding = 4 }),
    lovr.graphics.getDefaultFont()
  )
  local widget: Widget
  local measurements = measurement.new()
  local host = {
    live = function(): boolean
      return true
    end,
    interactive = function(): boolean
      return true
    end,
    captured = function(): boolean
      return true
    end,
    changed = function()
      state.changes += 1
    end,
    cancel = function() end,
    focus = function(): boolean
      state.focused = true
      widget.onFocus(true)
      return true
    end,
    blur = function(): boolean
      if not state.focused then
        return false
      end
      state.focused = false
      widget.onFocus(false)
      return true
    end,
    bounds = function(): Bounds
      return bounds
    end,
    clip = function(): Bounds
      return bounds
    end,
    theme = function(): Theme
      return theme
    end,
    textMeasurements = function(): measurement.Cache
      return measurements
    end,
    callback = function(_: string, run: () -> ()): boolean
      run()
      return true
    end,
  }
  local supplied: Options = table.clone(options or {})
  supplied.id = 'draft'
  supplied.bounds = bounds
  widget = textField.new(supplied, host)
  local function snapshot(): Visual
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

function fixture.key(code: number, modifiers: { ModifierName }?, source: ('virtual' | 'physical')?): KeyEvent
  return { code = code, modifiers = modifiers or {}, source = source or 'virtual', isRepeat = false }
end

function fixture.pointer<P>(
  pointer: P,
  kind: 'press' | 'move' | 'release',
  x: number,
  button: PointerButton?
): PointerEvent<P>
  return { pointer = pointer, kind = kind, x = x, y = 25, inside = true, captured = true, button = button }
end

return fixture
