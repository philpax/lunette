-- Action kinds: buttons in their variants, filter chips, and the tooltip that shows a disabled control's reason.

local uiHost = require '@lunette-contracts/ui-host'
local tokens = require './tokens'

local actions = {}

local element = uiHost.element

local function lighten(color: uiHost.Color, amount: number): uiHost.Color
  return {
    color[1] + (1 - color[1]) * amount,
    color[2] + (1 - color[2]) * amount,
    color[3] + (1 - color[3]) * amount,
    color[4] or 1,
  }
end

-- Activation reaches `onActivate`; hover changes reach `onHover`, which composites use to show a disabled reason.
local function pressable(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ()): ()
  if event.kind == 'activate' then
    if tokens.enabled(node.props) then
      node:emit 'onActivate'
    end
  elseif event.kind == 'hover-enter' then
    node:emit('onHover', true)
  elseif event.kind == 'hover-leave' then
    node:emit('onHover', false)
  elseif event.kind ~= 'press' and event.kind ~= 'release' then
    base(node, event)
  end
end

export type Variant = 'default' | 'primary' | 'quiet' | 'band' | 'selected'

-- The face colour, side colour, and ink of a button variant in its current state.
function actions.face(
  theme: uiHost.Theme,
  variant: Variant,
  enabled: boolean,
  state: { read [string]: any }
): (uiHost.Color?, uiHost.Color?, uiHost.Color)
  local colors = theme.colors
  if not enabled then
    return colors.sunken, nil, colors.muted
  end
  local hovered = state.hovered or state.pressed
  if variant == 'primary' or variant == 'selected' then
    return if hovered then lighten(colors.accent, 0.12) else colors.accent, colors.side, colors.accentInk
  elseif variant == 'quiet' then
    return if hovered then colors.hover else nil, nil, colors.ink
  elseif variant == 'band' then
    return if hovered then lighten(colors.header, 0.1) else nil, nil, colors.bandInk
  end
  return if hovered then colors.hover else colors.raised, colors.side, colors.ink
end

local function raisedVariant(variant: Variant): boolean
  return variant == 'default' or variant == 'primary' or variant == 'selected'
end

function actions.register(service: uiHost.Service, owner: any): { [string]: uiHost.Constructor }
  local constructors: { [string]: uiHost.Constructor } = {}

  service:registerKind(owner, {
    name = 'lunette/button-face',
    layout = {
      kind = 'container',
      style = function(props, theme)
        return {
          flexDirection = 'row',
          alignItems = 'center',
          justifyContent = 'center',
          gap = theme.spacing.sm,
          padding = {
            left = theme.spacing.md,
            right = theme.spacing.md,
            top = theme.spacing.xs,
            bottom = theme.spacing.xs,
          },
          minHeight = if props.variant == 'band' then theme.sizes.control * 0.9 else theme.sizes.control,
          minWidth = theme.sizes.control,
          grow = props.grow,
        }
      end,
    },
    elevation = function(props, theme)
      if not tokens.enabled(props) or not raisedVariant(props.variant or 'default') then
        return 0
      end
      return if props.variant == 'selected' then theme.elevation.selected else theme.elevation.raised
    end,
    response = { lift = true, travel = true },
    interactive = function()
      return true
    end,
    visuals = { 'lunette/button-face' },
    event = pressable,
  })
  service:registerVisual(owner, 'lunette/button-face', function(node, draw)
    local theme = node.theme
    local enabled = tokens.enabled(node.props)
    local fill, side = actions.face(theme, node.props.variant or 'default', enabled, node.state)
    if fill then
      draw:box(nil, {
        fill = fill,
        radius = theme.radii.control,
        side = side,
        edges = side ~= nil,
        border = if enabled then 0 else theme.sizes.rule,
        borderColor = theme.colors.line,
      })
    end
  end)

  service:registerKind(owner, {
    name = 'lunette/tooltip',
    layout = {
      kind = 'container',
      style = function(_props, theme)
        return {
          position = 'absolute',
          top = '100%',
          left = 0,
          margin = { top = theme.spacing.xs },
          padding = {
            left = theme.spacing.sm,
            right = theme.spacing.sm,
            top = theme.spacing.xs,
            bottom = theme.spacing.xs,
          },
          maxWidth = 0.2,
        }
      end,
    },
    elevation = 'popover',
    visuals = { 'lunette/tooltip' },
  })
  service:registerVisual(owner, 'lunette/tooltip', function(node, draw)
    local theme = node.theme
    draw:box(nil, { fill = theme.colors.band, radius = theme.radii.control, side = theme.colors.side, edges = true })
  end)

  -- Button props: label, variant ('default', 'primary', 'quiet', 'band'), onActivate, disabledReason, and grow.
  constructors.Button = service:registerKind(owner, {
    name = 'lunette/button',
    layout = {
      kind = 'container',
      style = function(props)
        -- The disabled reason's tooltip is placed against the button, so the button is positioned.
        return {
          flexDirection = 'column',
          alignItems = 'stretch',
          grow = props.grow,
          alignSelf = props.alignSelf,
          position = 'relative',
        }
      end,
    },
    state = { showReason = false },
    expand = function(props, children, state, act)
      local enabled = tokens.enabled(props)
      local variant = props.variant or 'default'
      local ink = if not enabled
        then 'muted'
        elseif variant == 'primary' or variant == 'selected' then 'accentInk'
        elseif variant == 'band' then 'bandInk'
        else 'ink'
      return {
        element('lunette/button-face', {
          key = 'face',
          variant = variant,
          grow = props.grow,
          disabledReason = props.disabledReason,
          onActivate = function()
            act.emit 'onActivate'
          end,
          onHover = function(hovered: boolean)
            act.setState { showReason = hovered and not enabled }
          end,
          if props.label
            then element(
              'lunette/text',
              { key = 'label', text = props.label, style = 'label', color = ink, wrap = false }
            )
            else nil,
          children,
        }),
        if state.showReason and props.disabledReason
          then element('lunette/tooltip', {
            key = 'reason',
            element('lunette/text', { text = props.disabledReason, style = 'caption', color = 'bandInk' }),
          })
          else nil,
      }
    end,
  })

  -- Chip props: label, selected, and onChange, which receives the new selection.
  constructors.Chip = service:registerKind(owner, {
    name = 'lunette/chip',
    expand = function(props, _children, _state, act)
      local selected = props.selected == true
      return {
        element('lunette/button-face', {
          key = 'face',
          variant = if selected then 'selected' else 'default',
          disabledReason = props.disabledReason,
          onActivate = function()
            act.emit('onChange', not selected)
          end,
          element('lunette/text', {
            key = 'label',
            text = props.label or '',
            style = 'label',
            color = if selected then 'accentInk' else 'ink',
            wrap = false,
          }),
        }),
      }
    end,
  })

  return constructors
end

return actions
