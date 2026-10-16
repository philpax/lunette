-- Text input kinds: a single-line text field that takes session focus when pressed, so the VR keyboard and a
-- physical keyboard type into it.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local schema = require '@lunette-plugin/schema'
local keys = require '@lunette-contracts/keys'
local tokens = require './tokens'
local shapes = require './props'

local optional = schema.optional
local edit = require './text-edit'

local fields = {}

local element = uiHost.element

local function has(modifiers: { read [number]: string }, name: string): boolean
  for _, modifier in modifiers do
    if modifier == name then
      return true
    end
  end
  return false
end

-- The x of a byte offset in shaped lines: the left edge of the first glyph at or after it, or the end of the line.
local function caretX(lines: { lunette.LayoutLine }?, offset: number): number
  local line = lines and lines[1]
  if not line or #line.glyphs == 0 then
    return 0
  end
  for _, glyph in line.glyphs do
    if glyph.byteStart >= offset then
      return glyph.x
    end
  end
  local last = line.glyphs[#line.glyphs]
  return last.x + last.advance
end

-- The grapheme boundary nearest an x, from the shaped glyphs and the value's boundaries.
local function offsetAt(lines: { lunette.LayoutLine }?, value: string, x: number): number
  local best, bestDistance = #value + 1, math.huge
  for _, boundary in lunette.textBoundaries(value) do
    local distance = math.abs(caretX(lines, boundary) - x)
    if distance < bestDistance then
      best, bestDistance = boundary, distance
    end
  end
  return best
end

function fields.register(service: uiHost.Service, owner: any): { [string]: uiHost.Constructor }
  local constructors: { [string]: uiHost.Constructor } = {}

  service:registerKind(owner, {
    name = 'lunette/field-face',
    props = schema.object {
      focused = optional(schema.boolean()),
      hovered = optional(schema.boolean()),
      invalid = optional(schema.boolean()),
      grow = optional(schema.number()),
    },
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'row',
          alignItems = 'center',
          gap = theme.spacing.sm,
          minHeight = theme.sizes.control,
          padding = { left = theme.spacing.md, right = theme.spacing.md },
          grow = props.grow,
        }
      end,
    },
    visuals = { 'lunette/field-face' },
  })
  -- A field is a well in the surface: a sunken face with a rule along its bottom that takes the accent colour while
  -- the field has focus.
  service:registerVisual(owner, 'lunette/field-face', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    local bounds = node.bounds
    local focused = node.props.focused == true
    draw:box(nil, {
      fill = if node.props.hovered and not focused then theme.colors.hover else theme.colors.sunken,
      radius = theme.radii.control,
    })
    local rule = if focused then theme.sizes.underline * 2 else theme.sizes.rule
    draw:box({ x = 0, y = bounds.height - rule, width = bounds.width, height = rule }, {
      fill = if focused
        then theme.colors.accent
        elseif node.props.invalid then theme.colors.danger
        else theme.colors.line,
    })
  end)

  service:registerKind(owner, {
    name = 'lunette/field-text',
    props = schema.object {
      value = optional(schema.string()),
      placeholder = optional(schema.string()),
      caret = optional(schema.number()),
      anchor = optional(schema.number()),
      focused = optional(schema.boolean()),
      mono = optional(schema.boolean()),
    },
    layout = {
      kind = 'text',
      text = function(props: uiHost.Props): string
        local value = tostring(props.value or '')
        return if value == '' then tostring(props.placeholder or '') else value
      end,
      style = function(): lunette.LayoutStyle
        return { grow = 1, shrink = 1 }
      end,
      textStyle = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutTextStyle
        return tokens.textStyle(theme, if props.mono then 'mono' else 'body', { wrap = 'none', maxLines = 1 })
      end,
    },
    visuals = { 'lunette/field-text' },
  })
  service:registerVisual(owner, 'lunette/field-text', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    local props = node.props
    local empty = props.value == ''
    local lines = node:textLines()
    if props.focused and not empty and props.caret ~= props.anchor then
      local caret, anchor = props.caret :: number, props.anchor :: number
      local first, last = math.min(caret, anchor), math.max(caret, anchor)
      local x1, x2 = caretX(lines, first), caretX(lines, last)
      draw:box(
        { x = x1, y = 0, width = x2 - x1, height = node.bounds.height },
        { fill = theme.colors.accent, offset = 0 }
      )
    end
    draw:text { color = if empty then theme.colors.muted else theme.colors.ink }
    if props.focused then
      local x = if empty then 0 else caretX(lines, props.caret)
      local width = theme.sizes.headerRule
      draw:box({ x = x - width / 2, y = 0, width = width, height = node.bounds.height }, {
        fill = theme.colors.accent,
        offset = theme.elevation.contentOffset * 2,
      })
    end
  end)

  -- TextField props: value, placeholder, onChange, onSubmit, onCancel, invalid, mono, prefix, unit, grow, and
  -- disabledReason. The field edits a draft while focused and reports each change; Enter submits and Escape leaves the
  -- field. A prefix, such as a vector component's axis, and a unit sit inside the field in muted monospace.
  constructors.TextField = service:registerKind(owner, {
    name = 'lunette/text-field',
    props = shapes.disableable {
      value = optional(schema.string()),
      placeholder = optional(schema.string()),
      onChange = optional(schema.callback(function(_value: string) end)),
      onSubmit = optional(schema.callback(function(_value: string) end)),
      onCancel = optional(schema.callback(function(_value: string) end)),
      invalid = optional(schema.boolean()),
      mono = optional(schema.boolean()),
      prefix = optional(schema.string()),
      unit = optional(schema.string()),
      grow = optional(schema.number()),
      alignSelf = optional(shapes.align),
    },
    role = 'textbox',
    semantics = function(props: uiHost.Props, state: { read [string]: any }): uiHost.Semantics
      return { value = props.value, disabled = props.disabledReason ~= nil }
    end,
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props): lunette.LayoutStyle
        return { flexDirection = 'column', alignItems = 'stretch', grow = props.grow, alignSelf = props.alignSelf }
      end,
    },
    focus = 'text',
    interactive = function(props: uiHost.Props): boolean
      return tokens.enabled(props)
    end,
    -- `seen` is the value prop the draft last agreed with, so a change from outside the field can be told from the
    -- consumer echoing the field's own edits.
    state = { draft = false, seen = false },
    event = function(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ())
      local props = node.props
      local fresh = not node.state.draft
      local draft: edit.State = node.state.draft or edit.new(tostring(props.value or ''))
      local function apply(next: edit.State, report: boolean): ()
        node:setState { draft = next, seen = if fresh then tostring(props.value or '') else node.state.seen }
        if report and next.value ~= draft.value then
          node:emit('onChange', next.value)
        end
      end
      if event.kind == 'press' then
        local text = node:descendant 'face/text'
        if text then
          local bounds, own = text:panelBounds(), node:panelBounds()
          local x = (event :: any).x - (bounds.x - own.x)
          apply(edit.select(draft, offsetAt(text:textLines(), draft.value, x)), false)
        end
      elseif event.kind == 'text' then
        local inserted = (event :: any).text :: string
        if inserted ~= '' then
          local ok, next = pcall(edit.insert, draft, inserted)
          if ok then
            apply(next, true)
          end
        end
      elseif event.kind == 'key' then
        local key = event :: any
        local codes = keys.CODES
        local shift, control = has(key.modifiers, 'shift'), has(key.modifiers, 'control')
        if has(key.modifiers, 'alt') or has(key.modifiers, 'logo') then
          base(node, event)
        elseif control and key.code == codes.a then
          apply(edit.select(draft, #draft.value + 1, 1), false)
        elseif key.code == codes.left or key.code == codes.right then
          apply(edit.move(draft, if key.code == codes.left then 'left' else 'right', shift), false)
        elseif key.code == codes.home or key.code == codes['end'] then
          apply(edit.move(draft, if key.code == codes.home then 'home' else 'end', shift), false)
        elseif key.code == codes.backspace or key.code == codes.delete then
          apply(edit.erase(draft, if key.code == codes.backspace then 'backward' else 'forward'), true)
        elseif key.code == codes.enter or key.code == codes.keypadEnter then
          node:emit('onSubmit', draft.value)
        elseif key.code == codes.escape then
          node:emit('onCancel', draft.value)
          node:setState { draft = false }
          node:blur()
        else
          base(node, event)
        end
      elseif
        event.kind ~= 'hover-enter'
        and event.kind ~= 'hover-leave'
        and event.kind ~= 'release'
        and event.kind ~= 'activate'
      then
        base(node, event)
      end
    end,
    expand = function(
      props: uiHost.Props,
      _children: { read [number]: uiHost.Element },
      state: { read [string]: any },
      actions: uiHost.Actions
    ): uiHost.Child
      local value = tostring(props.value or '')
      local draft = state.draft
      -- A value prop that changes to something other than the draft is a reset from outside the field, which
      -- replaces the draft even while the field is focused. A change to the draft's own value is the consumer
      -- echoing an edit, and the draft keeps its caret.
      if draft and value ~= state.seen then
        if value ~= draft.value then
          actions.setState { draft = false, seen = value }
          draft = nil
        else
          actions.setState { seen = value }
        end
      end
      local shown = if draft and state.focused then draft else edit.new(value)
      return element('lunette/field-face', {
        key = 'face',
        focused = state.focused,
        hovered = state.hovered,
        invalid = props.invalid,
        grow = props.grow,
        if props.prefix
          then element('lunette/text', { key = 'prefix', text = props.prefix, style = 'readout', color = 'muted' })
          else nil,
        element('lunette/field-text', {
          key = 'text',
          value = shown.value,
          placeholder = props.placeholder,
          caret = shown.caret,
          anchor = shown.anchor,
          focused = state.focused,
          mono = props.mono,
        }),
        if props.unit
          then element('lunette/text', { key = 'unit', text = props.unit, style = 'readout', color = 'muted' })
          else nil,
      })
    end,
  })

  return constructors
end

return fields
