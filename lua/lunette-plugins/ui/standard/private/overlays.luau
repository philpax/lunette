-- Overlay kinds: the dialog face and the toast card, which content panels with the dialog and follow presentations
-- show.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local schema = require '@lunette-plugin/schema'
local shapes = require './props'

local optional = schema.optional

local overlays = {}

local element = uiHost.element

function overlays.register(service: uiHost.Service, owner: any): { [string]: uiHost.Constructor }
  local constructors: { [string]: uiHost.Constructor } = {}

  service:registerKind(owner, {
    name = 'lunette/dialog-face',
    props = schema.object {
      minWidth = optional(shapes.length),
      maxWidth = optional(shapes.length),
    },
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'column',
          alignItems = 'stretch',
          gap = theme.spacing.md,
          padding = theme.spacing.lg,
          minWidth = props.minWidth or 0.26,
          maxWidth = props.maxWidth or 0.42,
        }
      end,
    },
    visuals = { 'lunette/dialog-face' },
  })
  service:registerVisual(owner, 'lunette/dialog-face', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    draw:box(nil, {
      fill = theme.colors.surface,
      radius = theme.radii.panel,
      side = theme.colors.side,
      depth = theme.elevation.panelDepth,
      edges = true,
      border = theme.sizes.headerRule,
      borderColor = theme.colors.headerRule,
    })
  end)

  -- Dialog props: title, actions ({ id, label, variant, onActivate }), and children for the body.
  constructors.Dialog = service:registerKind(owner, {
    name = 'lunette/dialog',
    props = schema.object {
      title = optional(schema.string()),
      actions = optional(schema.array(shapes.dialogAction)),
      minWidth = optional(shapes.length),
      maxWidth = optional(shapes.length),
    },
    role = 'dialog',
    semantics = function(props: uiHost.Props, state: { read [string]: any }): uiHost.Semantics
      return { name = props.title }
    end,
    expand = function(
      props: uiHost.Props,
      children: { read [number]: uiHost.Element },
      _state: { read [string]: any },
      _actions: uiHost.Actions
    ): uiHost.Child
      local buttons = {}
      for _, action in props.actions or {} do
        buttons[#buttons + 1] = element('lunette/button', {
          key = uiHost.keyOf(action.id),
          label = action.label,
          variant = action.variant or 'default',
          onActivate = action.onActivate,
          disabledReason = action.disabledReason,
        })
      end
      return element('lunette/dialog-face', {
        key = 'face',
        minWidth = props.minWidth,
        maxWidth = props.maxWidth,
        if props.title then element('lunette/text', { key = 'title', text = props.title, style = 'heading' }) else nil,
        element('lunette/column', { key = 'body', gap = 'sm', children }),
        if #buttons > 0
          then element('lunette/row', {
            key = 'actions',
            gap = 'sm',
            justify = 'end',
            buttons,
          })
          else nil,
      })
    end,
  })

  service:registerKind(owner, {
    name = 'lunette/toast-face',
    motion = { enter = 'fade', exit = 'fade' },
    props = schema.object {
      level = optional(shapes.level),
      onHover = optional(schema.callback(function(_hovered: boolean) end)),
    },
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'row',
          alignItems = 'start',
          gap = theme.spacing.md,
          padding = theme.spacing.md,
          width = 0.3,
        }
      end,
    },
    elevation = 'raised',
    interactive = function(): boolean
      return true
    end,
    visuals = { 'lunette/toast-face' },
    event = function(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ())
      if event.kind == 'hover-enter' then
        node:emit('onHover', true)
      elseif event.kind == 'hover-leave' then
        node:emit('onHover', false)
      elseif event.kind ~= 'press' and event.kind ~= 'release' and event.kind ~= 'activate' then
        base(node, event)
      end
    end,
  })
  service:registerVisual(owner, 'lunette/toast-face', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    local level = node.props.level
    draw:box(nil, { fill = theme.colors.raised, radius = theme.radii.panel, side = theme.colors.side, edges = true })
    -- The level shows as a square-cut rule along the top edge, in the accent or a status colour.
    local rule = if level == 'error'
      then theme.colors.danger
      elseif level == 'warning' then theme.colors.warning
      else theme.colors.accent
    draw:box({ x = 0, y = 0, width = node.bounds.width, height = theme.sizes.headerRule }, { fill = rule })
  end)

  -- Toast props: title, body, level ('info', 'warning', 'error'), actions, onHover, and onDismiss.
  constructors.Toast = service:registerKind(owner, {
    name = 'lunette/toast',
    props = schema.object {
      title = optional(schema.string()),
      body = optional(schema.string()),
      level = optional(shapes.level),
      actions = optional(schema.array(shapes.toastAction)),
      onHover = optional(schema.callback(function(_hovered: boolean) end)),
      onDismiss = optional(shapes.activate),
    },
    role = 'alert',
    semantics = function(props: uiHost.Props, state: { read [string]: any }): uiHost.Semantics
      return { name = props.title }
    end,
    expand = function(
      props: uiHost.Props,
      _children: { read [number]: uiHost.Element },
      _state: { read [string]: any },
      actions: uiHost.Actions
    ): uiHost.Child
      local buttons = {}
      for _, action in props.actions or {} do
        buttons[#buttons + 1] = element('lunette/button', {
          key = uiHost.keyOf(action.id),
          label = action.label,
          variant = 'quiet',
          onActivate = action.onActivate,
        })
      end
      return element('lunette/toast-face', {
        key = 'face',
        level = props.level,
        onHover = function(hovered: boolean)
          actions.emit('onHover', hovered)
        end,
        element('lunette/column', {
          key = 'text',
          grow = 1,
          shrink = 1,
          gap = 'xs',
          element('lunette/text', { key = 'title', text = props.title or '', style = 'label' }),
          if props.body
            then element('lunette/text', { key = 'body', text = props.body, style = 'caption', color = 'muted' })
            else nil,
          if #buttons > 0 then element('lunette/row', { key = 'actions', gap = 'xs', buttons }) else nil,
        }),
        if props.onDismiss
          then element('lunette/button', {
            key = 'dismiss',
            label = '×',
            variant = 'quiet',
            onActivate = function()
              actions.emit 'onDismiss'
            end,
          })
          else nil,
      })
    end,
  })

  return constructors
end

return overlays
