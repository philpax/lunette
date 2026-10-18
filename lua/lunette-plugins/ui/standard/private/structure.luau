-- Structure kinds: the panel face, header and section bands, layout containers, cards, and rules.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local schema = require '@lunette-plugin/schema'
local tokens = require './tokens'
local shapes = require './props'

local optional = schema.optional

local structure = {}

local element = uiHost.element

-- The header band is square at the bottom and follows the panel's rounded corners at the top: a rounded box with a
-- square box over its lower half.
local function topRounded(draw: uiHost.Draw, bounds: uiHost.Rect, radius: number, fill: uiHost.Color): ()
  draw:box(bounds, { fill = fill, radius = radius })
  local half = bounds.height / 2
  draw:box({ x = bounds.x, y = bounds.y + half, width = bounds.width, height = bounds.height - half }, { fill = fill })
end

function structure.register(service: uiHost.Service, owner: any): { [string]: uiHost.Constructor }
  local constructors: { [string]: uiHost.Constructor } = {}

  -- Panel props: the container props, and the chrome. A title gives the panel its header band, which shows the
  -- detail beside the title, a back button for onBack, a close button for onClose, and the children of any
  -- HeaderActions child. The band's empty space is a handle, so a trigger drag on it moves a grabbable panel.
  constructors.Panel = service:registerKind(owner, {
    name = 'lunette/panel',
    props = shapes.container {
      title = optional(schema.string()),
      detail = optional(schema.string()),
      onBack = optional(shapes.activate),
      onClose = optional(shapes.activate),
    },
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        local style = tokens.container(theme, props, 'column')
        return {
          flexDirection = 'column',
          alignItems = 'stretch',
          grow = 1,
          width = style.width,
          height = style.height,
          minWidth = style.minWidth,
          maxWidth = style.maxWidth,
          gap = style.gap,
          padding = style.padding,
        }
      end,
    },
    visuals = { 'lunette/panel' },
    expand = function(props: uiHost.Props, children: { read [number]: uiHost.Element }): uiHost.Child
      if props.title == nil then
        return children
      end
      local actions: { uiHost.Element } = {}
      local content: { uiHost.Element } = {}
      for _, child in children do
        if child.kind == 'lunette/header-actions' then
          actions[#actions + 1] = child
        else
          content[#content + 1] = child
        end
      end
      return {
        element('lunette/header', {
          key = 'header',
          title = props.title,
          detail = props.detail,
          onBack = props.onBack,
          onClose = props.onClose,
          actions,
        }),
        content,
      }
    end,
  })
  service:registerVisual(owner, 'lunette/panel', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    draw:box(nil, {
      fill = theme.colors.surface,
      radius = theme.radii.panel,
      side = theme.colors.side,
      depth = theme.elevation.panelDepth,
      edges = true,
    })
  end)

  constructors.Body = service:registerKind(owner, {
    name = 'lunette/body',
    props = shapes.container(),
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        local style = tokens.container(theme, props, 'column')
        return {
          flexDirection = 'column',
          alignItems = 'stretch',
          gap = tokens.space(theme, props.gap, theme.spacing.md),
          padding = tokens.space(theme, props.padding, theme.spacing.lg),
          grow = style.grow,
          -- A body can shrink below its content, so a scroll box inside it scrolls rather than growing the panel.
          shrink = 1,
          minHeight = 0,
        }
      end,
    },
  })

  service:registerKind(owner, {
    name = 'lunette/header-band',
    props = schema.object {},
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'row',
          alignItems = 'center',
          gap = theme.spacing.md,
          padding = { left = theme.spacing.lg, right = theme.spacing.lg },
          minHeight = theme.sizes.header,
        }
      end,
    },
    visuals = { 'lunette/header-band' },
    handle = true,
  })
  service:registerVisual(owner, 'lunette/header-band', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    local bounds = node.bounds
    topRounded(draw, bounds, theme.radii.panel, theme.colors.header)
    local rule = theme.sizes.headerRule
    draw:box(
      { x = 0, y = bounds.height - rule, width = bounds.width, height = rule },
      { fill = theme.colors.headerRule }
    )
  end)

  -- The actions a titled panel shows in its header band, before its close button.
  constructors.HeaderActions = service:registerKind(owner, {
    name = 'lunette/header-actions',
    props = schema.object {},
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return { flexDirection = 'row', alignItems = 'center', gap = theme.spacing.sm }
      end,
    },
  })

  service:registerKind(owner, {
    name = 'lunette/header',
    props = schema.object {
      title = optional(schema.string()),
      detail = optional(schema.string()),
      onBack = optional(shapes.activate),
      onClose = optional(shapes.activate),
    },
    role = 'heading',
    semantics = function(props: uiHost.Props, state: { read [string]: any }): uiHost.Semantics
      return { name = props.title }
    end,
    expand = function(props: uiHost.Props, children: { read [number]: uiHost.Element }): uiHost.Child
      return {
        element('lunette/header-band', {
          key = 'band',
          if props.onBack
            then element('lunette/button', {
              key = 'back',
              label = '‹',
              variant = 'band',
              onActivate = props.onBack,
            })
            else nil,
          -- The detail shares the title's baseline rather than centring its smaller line box beside it.
          element('lunette/row', {
            align = 'baseline',
            gap = 'md',
            element('lunette/text', { key = 'title', text = props.title or '', style = 'heading', color = 'bandInk' }),
            if props.detail
              then element(
                'lunette/text',
                { key = 'detail', text = props.detail, style = 'readout', color = 'headerMuted' }
              )
              else nil,
          }),
          element('lunette/spacer', { key = 'spacer' }),
          children,
          if props.onClose
            then element('lunette/button', {
              key = 'close',
              label = '×',
              variant = 'band',
              onActivate = props.onClose,
            })
            else nil,
        }),
      }
    end,
  })

  service:registerKind(owner, {
    name = 'lunette/section-band',
    props = schema.object {},
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        local bleed = theme.spacing.lg
        return {
          flexDirection = 'row',
          alignItems = 'center',
          minHeight = theme.sizes.section,
          padding = { left = bleed, right = bleed },
          margin = { left = -bleed, right = -bleed },
        }
      end,
    },
    visuals = { 'lunette/section-band' },
  })
  service:registerVisual(owner, 'lunette/section-band', function(node: uiHost.Node, draw: uiHost.Draw)
    draw:box(nil, { fill = node.theme.colors.section })
  end)

  -- Section headers fill their row: the band bleeds through the body's padding to the panel's edges.
  constructors.Section = service:registerKind(owner, {
    name = 'lunette/section',
    props = schema.object {
      title = optional(schema.string()),
      gap = optional(shapes.space),
    },
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return { flexDirection = 'column', alignItems = 'stretch', gap = theme.spacing.md }
      end,
    },
    expand = function(props: uiHost.Props, children: { read [number]: uiHost.Element }): uiHost.Child
      return {
        element('lunette/section-band', {
          key = 'band',
          element('lunette/text', {
            key = 'title',
            text = string.upper(props.title or ''),
            style = 'section',
            color = 'sectionInk',
          }),
        }),
        element('lunette/column', { key = 'content', gap = props.gap or 'md', children }),
      }
    end,
  })

  constructors.Column = service:registerKind(owner, {
    name = 'lunette/column',
    props = shapes.container(),
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return tokens.container(theme, props, 'column')
      end,
    },
  })

  constructors.Row = service:registerKind(owner, {
    name = 'lunette/row',
    props = shapes.container(),
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        local style = tokens.container(theme, props, 'row')
        return table.freeze(style)
      end,
    },
  })

  constructors.Card = service:registerKind(owner, {
    name = 'lunette/card',
    props = shapes.container(),
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        local style = tokens.container(theme, props, 'column')
        return {
          flexDirection = 'column',
          alignItems = 'stretch',
          gap = tokens.space(theme, props.gap, theme.spacing.sm),
          padding = tokens.space(theme, props.padding, theme.spacing.md),
          grow = style.grow,
          width = style.width,
        }
      end,
    },
    elevation = 'raised',
    visuals = { 'lunette/card' },
  })
  service:registerVisual(owner, 'lunette/card', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    draw:box(nil, { fill = theme.colors.raised, radius = theme.radii.control, side = theme.colors.side, edges = true })
  end)

  constructors.Separator = service:registerKind(owner, {
    name = 'lunette/separator',
    props = schema.object {},
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return { height = theme.sizes.rule * 2, alignSelf = 'stretch' }
      end,
    },
    visuals = { 'lunette/separator' },
  })
  service:registerVisual(owner, 'lunette/separator', function(node: uiHost.Node, draw: uiHost.Draw)
    draw:box(nil, { fill = node.theme.colors.line })
  end)

  constructors.Spacer = service:registerKind(owner, {
    name = 'lunette/spacer',
    props = schema.object {
      grow = optional(schema.number()),
      width = optional(shapes.length),
      height = optional(shapes.length),
    },
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props): lunette.LayoutStyle
        return { grow = props.grow or 1, width = props.width, height = props.height }
      end,
    },
  })

  -- The outlet kind belongs to the host, so its constructor names the kind without registering it.
  constructors.Outlet = function(props: { [any]: any }?): uiHost.Element
    return element('lunette/outlet', props)
  end
  return constructors
end

return structure
