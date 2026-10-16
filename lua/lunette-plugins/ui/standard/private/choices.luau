-- Choice kinds: toggles, checkboxes, radio groups, segmented controls, and dropdowns.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local tokens = require './tokens'

local choices = {}

local element = uiHost.element

local function activateOnly(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ()): ()
  if event.kind == 'activate' then
    if tokens.enabled(node.props) then
      node:emit 'onActivate'
    end
  elseif
    event.kind ~= 'press'
    and event.kind ~= 'release'
    and event.kind ~= 'hover-enter'
    and event.kind ~= 'hover-leave'
  then
    base(node, event)
  end
end

-- A check mark as two bars, in the box's coordinates, as a fraction of its size.
function choices.checkMark(
  draw: uiHost.Draw,
  x: number,
  y: number,
  size: number,
  color: uiHost.Color,
  offset: number
): ()
  local stroke = size * 0.14
  local function bar(x1: number, y1: number, x2: number, y2: number): ()
    local ax, ay, bx, by = x + x1 * size, y + y1 * size, x + x2 * size, y + y2 * size
    local length = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) + stroke
    draw:box({ x = (ax + bx) / 2 - length / 2, y = (ay + by) / 2 - stroke / 2, width = length, height = stroke }, {
      fill = color,
      radius = stroke / 2,
      rotation = math.atan2(by - ay, bx - ax),
      offset = offset,
    })
  end
  bar(0.24, 0.52, 0.42, 0.7)
  bar(0.42, 0.7, 0.76, 0.32)
end

-- A downward chevron, centred in the box.
function choices.chevron(draw: uiHost.Draw, bounds: uiHost.Rect, color: uiHost.Color, open: boolean): ()
  local size = math.min(bounds.width, bounds.height)
  local stroke = size * 0.14
  local cx, cy = bounds.x + bounds.width / 2, bounds.y + bounds.height / 2
  local reach = size * 0.22
  local lift = if open then reach * 0.5 else -reach * 0.5
  for _, side in { -1, 1 } do
    local length = math.sqrt(2) * reach + stroke
    local angle = if open then -side * math.pi / 4 else side * math.pi / 4
    draw:box({ x = cx + side * reach / 2 - length / 2, y = cy - lift - stroke / 2, width = length, height = stroke }, {
      fill = color,
      radius = stroke / 2,
      rotation = angle,
    })
  end
end

function choices.register(service: uiHost.Service, owner: any): { [string]: uiHost.Constructor }
  local constructors: { [string]: uiHost.Constructor } = {}

  -- A row that the whole of activates, with a quiet hover fill.
  service:registerKind(owner, {
    name = 'lunette/choice-row',
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'row',
          alignItems = 'center',
          gap = theme.spacing.md,
          minHeight = theme.sizes.row,
          padding = { left = theme.spacing.sm, right = theme.spacing.sm },
          margin = { left = -theme.spacing.sm, right = -theme.spacing.sm },
        }
      end,
    },
    interactive = function(props: uiHost.Props): boolean
      return tokens.enabled(props)
    end,
    visuals = { 'lunette/choice-row' },
    event = activateOnly,
  })
  service:registerVisual(owner, 'lunette/choice-row', function(node: uiHost.Node, draw: uiHost.Draw)
    if node.state.hovered then
      draw:box(nil, { fill = node.theme.colors.hover, radius = node.theme.radii.control })
    end
  end)

  service:registerKind(owner, {
    name = 'lunette/switch',
    layout = {
      kind = 'leaf',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return { width = theme.sizes.toggleWidth, height = theme.sizes.toggleHeight, shrink = 0 }
      end,
    },
    visuals = { 'lunette/switch' },
  })
  service:registerVisual(owner, 'lunette/switch', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    local bounds = node.bounds
    local on = node.props.value == true
    local enabled = tokens.enabled(node.props)
    draw:box(nil, {
      fill = if on and enabled then theme.colors.accent else theme.colors.rail,
      radius = theme.radii.control,
    })
    -- The thumb stands proud of the track, as a key does.
    local inset = theme.spacing.xs * 0.75
    local size = bounds.height - inset * 2
    local x = if on then bounds.width - inset - size else inset
    draw:box({ x = x, y = inset, width = size, height = size }, {
      fill = if enabled then theme.colors.raised else theme.colors.sunken,
      radius = theme.radii.control,
      side = theme.colors.side,
      offset = theme.elevation.raised,
      edges = true,
    })
  end)

  local function label(props: uiHost.Props, key: string): uiHost.Element
    return element('lunette/column', {
      key = key,
      grow = 1,
      shrink = 1,
      element('lunette/text', {
        key = 'label',
        text = props.label or '',
        style = 'body',
        color = if tokens.enabled(props) then 'ink' else 'muted',
      }),
      if props.detail
        then element('lunette/text', { key = 'detail', text = props.detail, style = 'caption', color = 'muted' })
        else nil,
      if props.disabledReason
        then element(
          'lunette/text',
          { key = 'reason', text = props.disabledReason, style = 'caption', color = 'muted' }
        )
        else nil,
    })
  end

  -- Toggle props: label, detail, value, onChange, and disabledReason.
  constructors.Toggle = service:registerKind(owner, {
    name = 'lunette/toggle',
    expand = function(
      props: uiHost.Props,
      _children: { read [number]: uiHost.Element },
      _state: { read [string]: any },
      act: uiHost.Actions
    ): uiHost.Child
      return {
        element('lunette/choice-row', {
          key = 'row',
          disabledReason = props.disabledReason,
          onActivate = function()
            act.emit('onChange', not props.value)
          end,
          label(props, 'text'),
          element('lunette/switch', { key = 'switch', value = props.value, disabledReason = props.disabledReason }),
        }),
      }
    end,
  })

  service:registerKind(owner, {
    name = 'lunette/check',
    layout = {
      kind = 'leaf',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return { width = theme.sizes.check, height = theme.sizes.check, shrink = 0 }
      end,
    },
    visuals = { 'lunette/check' },
  })
  service:registerVisual(owner, 'lunette/check', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    local bounds = node.bounds
    local on = node.props.value == true
    local round = node.props.shape == 'round'
    local selectedLift = if on and round then theme.elevation.selected else theme.elevation.raised * 0.6
    local radius = if round then bounds.width / 2 else theme.radii.control
    draw:box(nil, {
      fill = if on then theme.colors.accent else theme.colors.raised,
      radius = radius,
      side = theme.colors.side,
      offset = selectedLift,
      edges = true,
    })
    if on and round then
      local dot = bounds.width * 0.36
      draw:box({ x = (bounds.width - dot) / 2, y = (bounds.height - dot) / 2, width = dot, height = dot }, {
        fill = theme.colors.accentInk,
        radius = dot / 2,
        offset = selectedLift,
      })
    elseif on then
      choices.checkMark(draw, 0, 0, bounds.width, theme.colors.accentInk, selectedLift)
    end
  end)

  -- Checkbox props: label, detail, value, onChange, and disabledReason.
  constructors.Checkbox = service:registerKind(owner, {
    name = 'lunette/checkbox',
    expand = function(
      props: uiHost.Props,
      _children: { read [number]: uiHost.Element },
      _state: { read [string]: any },
      act: uiHost.Actions
    ): uiHost.Child
      return {
        element('lunette/choice-row', {
          key = 'row',
          disabledReason = props.disabledReason,
          onActivate = function()
            act.emit('onChange', not props.value)
          end,
          element('lunette/check', { key = 'box', value = props.value }),
          label(props, 'text'),
        }),
      }
    end,
  })

  -- RadioGroup props: options, value, and onChange, which receives the chosen option's id.
  constructors.RadioGroup = service:registerKind(owner, {
    name = 'lunette/radio-group',
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return { flexDirection = 'column', alignItems = 'stretch', gap = theme.spacing.xs }
      end,
    },
    expand = function(
      props: uiHost.Props,
      _children: { read [number]: uiHost.Element },
      _state: { read [string]: any },
      act: uiHost.Actions
    ): uiHost.Child
      local rows = {}
      for _, option in props.options or {} do
        rows[#rows + 1] = element('lunette/choice-row', {
          key = uiHost.keyOf(option.id),
          disabledReason = option.disabledReason,
          onActivate = function()
            act.emit('onChange', option.id)
          end,
          element('lunette/check', { key = 'disc', value = option.id == props.value, shape = 'round' }),
          label(option, 'text'),
        })
      end
      return rows
    end,
  })

  service:registerKind(owner, {
    name = 'lunette/segment',
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'row',
          alignItems = 'center',
          justifyContent = 'center',
          grow = 1,
          minHeight = theme.sizes.control - theme.spacing.xs,
          padding = { left = theme.spacing.md, right = theme.spacing.md },
        }
      end,
    },
    elevation = function(props: uiHost.Props, theme: uiHost.Theme): number
      return if props.selected then theme.elevation.raised else 0
    end,
    response = { lift = true, travel = true },
    interactive = function(props: uiHost.Props): boolean
      return tokens.enabled(props)
    end,
    visuals = { 'lunette/segment' },
    event = activateOnly,
  })
  -- A selected segment or tab is a raised face with a square accent underline.
  service:registerVisual(owner, 'lunette/segment', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    local bounds = node.bounds
    if node.props.selected then
      draw:box(nil, {
        fill = if node.state.hovered then theme.colors.hover else theme.colors.raised,
        radius = theme.radii.control,
        side = theme.colors.side,
        edges = true,
      })
      local line = theme.sizes.underline * 2
      draw:box({ x = 0, y = bounds.height - line, width = bounds.width, height = line }, { fill = theme.colors.accent })
    elseif node.state.hovered then
      draw:box(nil, { fill = theme.colors.hover, radius = theme.radii.control })
    end
  end)

  service:registerKind(owner, {
    name = 'lunette/segment-track',
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'row',
          gap = theme.spacing.xs,
          padding = theme.spacing.xs * 0.75,
          alignSelf = props.alignSelf or 'stretch',
        }
      end,
    },
    visuals = { 'lunette/segment-track' },
  })
  service:registerVisual(owner, 'lunette/segment-track', function(node: uiHost.Node, draw: uiHost.Draw)
    draw:box(nil, { fill = node.theme.colors.sunken, radius = node.theme.radii.control })
  end)

  -- Segmented props: options, value, and onChange.
  constructors.Segmented = service:registerKind(owner, {
    name = 'lunette/segmented',
    expand = function(
      props: uiHost.Props,
      _children: { read [number]: uiHost.Element },
      _state: { read [string]: any },
      act: uiHost.Actions
    ): uiHost.Child
      local segments = {}
      for _, option in props.options or {} do
        local selected = option.id == props.value
        segments[#segments + 1] = element('lunette/segment', {
          key = uiHost.keyOf(option.id),
          selected = selected,
          disabledReason = option.disabledReason,
          onActivate = function()
            act.emit('onChange', option.id)
          end,
          element('lunette/text', {
            key = 'label',
            text = option.label,
            style = 'label',
            color = if selected then 'ink' else 'muted',
            wrap = false,
          }),
        })
      end
      return { element('lunette/segment-track', { key = 'track', alignSelf = props.alignSelf, segments }) }
    end,
  })

  constructors.Dropdown = choices.registerDropdown(service, owner)
  return constructors
end

function choices.registerDropdown(service: uiHost.Service, owner: any): uiHost.Constructor
  service:registerKind(owner, {
    name = 'lunette/chevron',
    layout = {
      kind = 'leaf',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return { width = theme.spacing.lg, height = theme.spacing.lg, shrink = 0 }
      end,
    },
    visuals = { 'lunette/chevron' },
  })
  service:registerVisual(owner, 'lunette/chevron', function(node: uiHost.Node, draw: uiHost.Draw)
    choices.chevron(draw, node.bounds, node.theme.colors.muted, node.props.open == true)
  end)

  service:registerKind(owner, {
    name = 'lunette/menu',
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'column',
          alignItems = 'stretch',
          padding = theme.spacing.xs,
          gap = theme.spacing.xs * 0.5,
        }
      end,
    },
    elevation = 'popover',
    visuals = { 'lunette/menu' },
  })
  service:registerVisual(owner, 'lunette/menu', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    draw:box(nil, { fill = theme.colors.raised, radius = theme.radii.control, side = theme.colors.side, edges = true })
  end)

  service:registerKind(owner, {
    name = 'lunette/menu-item',
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'row',
          alignItems = 'center',
          gap = theme.spacing.sm,
          minHeight = theme.sizes.control,
          padding = { left = theme.spacing.sm, right = theme.spacing.sm },
        }
      end,
    },
    interactive = function(props: uiHost.Props): boolean
      return tokens.enabled(props)
    end,
    visuals = { 'lunette/menu-item' },
    event = activateOnly,
  })
  service:registerVisual(owner, 'lunette/menu-item', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    if node.state.hovered then
      draw:box(nil, { fill = theme.colors.hover, radius = theme.radii.control })
    end
    -- The current item carries a check.
    if node.props.current then
      local size = theme.spacing.lg
      choices.checkMark(draw, theme.spacing.sm * 0.5, (node.bounds.height - size) / 2, size, theme.colors.accent, 0)
    end
  end)

  -- Dropdown props: options, value, onChange, and placeholder. The menu opens below the trigger.
  return service:registerKind(owner, {
    name = 'lunette/dropdown',
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props): lunette.LayoutStyle
        return {
          flexDirection = 'column',
          alignItems = 'stretch',
          alignSelf = props.alignSelf,
          grow = props.grow,
        }
      end,
    },
    state = { open = false },
    expand = function(
      props: uiHost.Props,
      _children: { read [number]: uiHost.Element },
      state: { read [string]: any },
      act: uiHost.Actions
    ): uiHost.Child
      local selected = nil
      for _, option in props.options or {} do
        if option.id == props.value then
          selected = option
        end
      end
      local items = {}
      if state.open then
        for _, option in props.options or {} do
          items[#items + 1] = element('lunette/menu-item', {
            key = uiHost.keyOf(option.id),
            current = option.id == props.value,
            disabledReason = option.disabledReason,
            onActivate = function()
              act.setState { open = false }
              act.emit('onChange', option.id)
            end,
            element('lunette/spacer', { key = 'mark', grow = 0, width = 0.012 }),
            element('lunette/text', { key = 'label', text = option.label, style = 'body', wrap = false }),
          })
        end
      end
      return {
        element('lunette/button-face', {
          key = 'trigger',
          variant = 'default',
          onActivate = function()
            act.setState(function(current: { read [string]: any }): { [string]: any }
              return { open = not current.open }
            end)
          end,
          element('lunette/text', {
            key = 'value',
            text = if selected then selected.label else props.placeholder or '',
            style = 'body',
            color = if selected then 'ink' else 'muted',
            grow = 1,
            wrap = false,
          }),
          element('lunette/chevron', { key = 'chevron', open = state.open }),
        }),
        -- The menu is an overlay: it extends past the dropdown's panel and closes on a press outside it.
        if state.open
          then element('lunette/portal', {
            key = 'menu',
            matchWidth = true,
            onDismiss = function()
              act.setState { open = false }
            end,
            element('lunette/menu', { items }),
          })
          else nil,
      }
    end,
  })
end

return choices
