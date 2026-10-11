local testing = require '@testing'
local textField = require '../../text-field'
local themes = require '../../theme'
local measurement = require '../../measurement-cache'

type ui = typeof(require '@lunette-contracts/ui')
type focus = typeof(require '@lunette-contracts/focus')
type lunette = typeof(require '@lunette')
type render = typeof(require '@testing/render')

type Options = {
  value: string?,
  onChange: ((string) -> ())?,
  onSubmit: ((string) -> ())?,
  onCancel: ((string) -> ())?,
  id: string?,
  bounds: ui.Bounds?,
}
type Methods = {
  value: (Methods) -> string,
  setValue: (Methods, string) -> (),
  setError: (Methods, string?) -> (),
  focus: (Methods) -> boolean,
  blur: (Methods) -> boolean,
}
type Theme = {
  read background: ui.Color,
  read foreground: ui.Color,
  read control: ui.Color,
  read hovered: ui.Color,
  read pressed: ui.Color,
  read disabled: ui.Color,
  read focus: ui.Color,
  read selection: ui.Color,
  read error: ui.Color,
  read border: ui.Color,
  read font: render.Font,
  read fontSize: number,
  read panelRadius: number,
  read controlRadius: number,
  read padding: number,
  read spacing: number,
  read borderWidth: number,
  read rowHeight: number,
  read hapticStrength: number,
  read hapticDuration: number,
}
type Visual = {
  id: string,
  kind: 'text-field'?,
  label: string,
  bounds: ui.Bounds,
  clip: ui.Bounds,
  theme: Theme,
  enabled: boolean,
  hovered: boolean,
  pressed: boolean,
  focused: boolean,
  items: { ui.ItemDescription },
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
  button: lunette.PointerButton?,
}
type Widget = {
  methods: Methods,
  kind: 'text-field'?,
  receiver: focus.Receiver,
  wantsKeyboard: boolean,
  onFocus: (boolean) -> (),
  pointer: <P>(PointerEvent<P>) -> (),
  visual: (Visual) -> Visual,
}
export type Fixture = {
  field: Methods,
  widget: Widget,
  receiver: focus.Receiver,
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
    bounds = function(): ui.Bounds
      return bounds
    end,
    clip = function(): ui.Bounds
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

function fixture.key(
  code: number,
  modifiers: { lunette.ModifierName }?,
  source: ('virtual' | 'physical')?
): focus.KeyEvent
  return { code = code, modifiers = modifiers or {}, source = source or 'virtual', isRepeat = false }
end

function fixture.pointer<P>(
  pointer: P,
  kind: 'press' | 'move' | 'release',
  x: number,
  button: lunette.PointerButton?
): PointerEvent<P>
  return { pointer = pointer, kind = kind, x = x, y = 25, inside = true, captured = true, button = button }
end

return fixture
