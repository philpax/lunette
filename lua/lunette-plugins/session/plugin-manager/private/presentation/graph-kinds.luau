-- Registers the dependency graph's kinds: a clipping canvas that draws edges as lines and reports pointer gestures,
-- node cards, and edge labels. Nodes and labels are children positioned absolutely in canvas metres.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'

local graphKinds = {}

export type Constructors = {
  read Canvas: uiHost.Constructor,
  read Node: uiHost.Constructor,
  read Label: uiHost.Constructor,
}

-- A line in canvas metres, coloured by its role.
export type Line = {
  read x1: number,
  read y1: number,
  read x2: number,
  read y2: number,
  read role: 'selected' | 'dependency' | 'ownership',
}

-- A colour role of the theme, for a node's status stripe.
export type Status = 'danger' | 'warning' | 'success' | 'muted' | 'ink'

local LINE_WIDTH = 0.0012
local SELECTED_WIDTH = 0.0024

-- Selection reaches `onActivate`; presses and hover belong to the host's response.
local function activateOnly(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ()): ()
  if event.kind == 'activate' then
    node:emit 'onActivate'
  elseif
    event.kind ~= 'press'
    and event.kind ~= 'release'
    and event.kind ~= 'hover-enter'
    and event.kind ~= 'hover-leave'
  then
    base(node, event)
  end
end

local function absolute(props: uiHost.Props, extra: lunette.LayoutStyle): lunette.LayoutStyle
  local style = table.clone(extra) :: { [string]: any }
  style.position = 'absolute'
  style.left = props.left
  style.top = props.top
  style.width = props.width
  style.height = props.height
  return style :: any
end

function graphKinds.register(host: uiHost.Service, owner: plugin.Owner): Constructors
  -- Canvas props: lines, and onPress, onDrag, onRelease, onCancel, and onScroll, which receive canvas metres; onScroll
  -- receives the scroll amount before the position.
  local canvas = host:registerKind(owner, {
    name = 'plugin-manager/graph-canvas',
    layout = {
      kind = 'container',
      style = function(): lunette.LayoutStyle
        return { grow = 1, shrink = 1, basis = 0, minHeight = 0, alignSelf = 'stretch', overflow = 'clip' }
      end,
    },
    clip = true,
    claims = { drag = 'both' },
    interactive = function(): boolean
      return true
    end,
    visuals = { 'plugin-manager/graph-canvas' },
    event = function(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ()): ()
      if event.kind == 'press' then
        node:emit('onPress', event.x, event.y)
      elseif event.kind == 'drag' then
        node:emit('onDrag', event.x, event.y)
      elseif event.kind == 'release' then
        node:emit('onRelease', event.x, event.y, event.inside)
      elseif event.kind == 'cancel' then
        node:emit 'onCancel'
      elseif event.kind == 'scroll' then
        node:emit('onScroll', event.dy, event.x, event.y)
      elseif
        event.kind ~= 'hover-enter'
        and event.kind ~= 'hover-leave'
        and event.kind ~= 'activate'
        and event.kind ~= 'drag-start'
        and event.kind ~= 'drag-end'
      then
        base(node, event)
      end
    end,
  })
  host:registerVisual(owner, 'plugin-manager/graph-canvas', function(node: uiHost.Node, draw: uiHost.Draw): ()
    local theme = node.theme
    local colors = theme.colors
    draw:box(nil, { fill = colors.sunken, radius = theme.radii.control })
    for _, line in (node.props.lines or {}) :: { Line } do
      local selected = line.role == 'selected'
      draw:line(line.x1, line.y1, line.x2, line.y2, {
        width = if selected then SELECTED_WIDTH else LINE_WIDTH,
        color = if selected then colors.accent elseif line.role == 'ownership' then colors.muted else colors.line,
        offset = theme.elevation.minimumSeparation,
      })
    end
  end)

  -- Node props: left, top, width, height, status, selected, onActivate, and the card's text as children.
  local graphNode = host:registerKind(owner, {
    name = 'plugin-manager/graph-node',
    focus = 'pointer',
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return absolute(props, {
          flexDirection = 'column',
          justifyContent = 'center',
          padding = { left = theme.spacing.md, right = theme.spacing.sm },
        })
      end,
    },
    clip = true,
    elevation = function(props: uiHost.Props, theme: uiHost.Theme): number
      return if props.selected then theme.elevation.selected else theme.elevation.raised
    end,
    response = { lift = true, travel = true },
    interactive = function(): boolean
      return true
    end,
    visuals = { 'plugin-manager/graph-node' },
    event = activateOnly,
  })
  host:registerVisual(owner, 'plugin-manager/graph-node', function(node: uiHost.Node, draw: uiHost.Draw): ()
    local theme = node.theme
    local colors = theme.colors
    local selected = node.props.selected == true
    draw:box(nil, {
      fill = if node.state.hovered then colors.hover else colors.raised,
      radius = theme.radii.control,
      side = colors.side,
      edges = true,
      border = if selected then theme.sizes.underline * 1.5 else theme.sizes.rule,
      borderColor = if selected then colors.accent else colors.line,
    })
    local status = (colors :: any)[node.props.status or 'ink'] or colors.ink
    draw:box({ x = 0, y = 0, width = theme.spacing.xs * 1.5, height = node.bounds.height }, { fill = status })
  end)

  -- Label props: left, top, selected, onActivate, and the label's text as a child.
  local label = host:registerKind(owner, {
    name = 'plugin-manager/graph-label',
    focus = 'pointer',
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return absolute(props, {
          padding = {
            left = theme.spacing.xs,
            right = theme.spacing.xs,
            top = theme.spacing.xs * 0.5,
            bottom = theme.spacing.xs * 0.5,
          },
          maxWidth = props.maxWidth,
        })
      end,
    },
    elevation = function(props: uiHost.Props, theme: uiHost.Theme): number
      return if props.selected then theme.elevation.raised else theme.elevation.minimumSeparation * 2
    end,
    response = { lift = true },
    interactive = function(): boolean
      return true
    end,
    visuals = { 'plugin-manager/graph-label' },
    event = activateOnly,
  })
  host:registerVisual(owner, 'plugin-manager/graph-label', function(node: uiHost.Node, draw: uiHost.Draw): ()
    local theme = node.theme
    local colors = theme.colors
    local fill = if node.props.selected
      then colors.accent
      elseif node.state.hovered then colors.hover
      else colors.surface
    draw:box(nil, { fill = fill, radius = theme.radii.control })
  end)

  return table.freeze { Canvas = canvas, Node = graphNode, Label = label }
end

return graphKinds
