-- Collection kinds: lists of rows, tables, and tabs. A selected row takes a solid accent fill with the accent's ink
-- and stands taller than the rows around it.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local tokens = require './tokens'

local collections = {}

local element = uiHost.element

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

-- The cells of a table row: a fixed share of the width where the column gives one, and an equal share otherwise.
local function cells(
  columns: { any },
  values: { read [number]: string },
  style: string,
  color: string
): { uiHost.Element }
  local list: { uiHost.Element } = {}
  for index, column in columns do
    list[index] = element('lunette/text', {
      key = column.id,
      text = values[index] or '',
      style = style,
      color = color,
      wrap = false,
      grow = if column.width then 0 else 1,
      basis = if column.width then column.width else 0,
      shrink = 1,
      maxLines = 1,
    })
  end
  return list
end

function collections.register(service: uiHost.Service, owner: any): { [string]: uiHost.Constructor }
  local constructors: { [string]: uiHost.Constructor } = {}

  service:registerKind(owner, {
    name = 'lunette/row-face',
    focus = 'pointer',
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'row',
          alignItems = 'center',
          gap = theme.spacing.md,
          minHeight = if props.compact then theme.sizes.control else theme.sizes.row,
          padding = {
            left = theme.spacing.md,
            right = theme.spacing.md,
            top = theme.spacing.xs,
            bottom = theme.spacing.xs,
          },
        }
      end,
    },
    elevation = function(props: uiHost.Props, theme: uiHost.Theme): number
      return if props.selected then theme.elevation.selected else theme.elevation.raised * 0.5
    end,
    response = { lift = true, travel = true },
    interactive = function(props: uiHost.Props): boolean
      return props.onActivate ~= nil and tokens.enabled(props)
    end,
    visuals = { 'lunette/row-face' },
    event = activateOnly,
  })
  service:registerVisual(owner, 'lunette/row-face', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    local colors = theme.colors
    local fill = if node.props.selected then colors.accent elseif node.state.hovered then colors.hover else colors.raised
    draw:box(nil, { fill = fill, radius = theme.radii.control, side = colors.side, edges = true })
  end)

  -- ListRow props: title, detail, trailing, selected, and onActivate.
  constructors.ListRow = service:registerKind(owner, {
    name = 'lunette/list-row',
    expand = function(
      props: uiHost.Props,
      children: { read [number]: uiHost.Element },
      _state: { read [string]: any },
      act: uiHost.Actions
    ): uiHost.Child
      local selected = props.selected == true
      return {
        element('lunette/row-face', {
          key = 'face',
          selected = selected,
          onActivate = if props.onActivate
            then function()
              act.emit 'onActivate'
            end
            else nil,
          element('lunette/column', {
            key = 'text',
            grow = 1,
            shrink = 1,
            element('lunette/text', {
              key = 'title',
              text = props.title or '',
              style = 'label',
              color = if selected then 'accentInk' else 'ink',
              maxLines = 1,
            }),
            if props.detail
              then element('lunette/text', {
                key = 'detail',
                text = props.detail,
                style = 'caption',
                color = if selected then 'accentInk' else 'muted',
                maxLines = 1,
              })
              else nil,
          }),
          if props.trailing
            then element('lunette/text', {
              key = 'trailing',
              text = props.trailing,
              style = 'body',
              color = if selected then 'accentInk' else props.trailingColor or 'muted',
              wrap = false,
            })
            else nil,
          children,
        }),
      }
    end,
  })

  -- List props: items ({ id, title, detail, trailing }), value, and onChange; or ListRow children.
  constructors.List = service:registerKind(owner, {
    name = 'lunette/list',
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'column',
          alignItems = 'stretch',
          gap = tokens.space(theme, props.gap, theme.spacing.xs),
        }
      end,
    },
    expand = function(
      props: uiHost.Props,
      children: { read [number]: uiHost.Element },
      _state: { read [string]: any },
      act: uiHost.Actions
    ): uiHost.Child
      local rows = {}
      for _, item in props.items or {} do
        rows[#rows + 1] = element('lunette/list-row', {
          key = uiHost.keyOf(item.id),
          title = item.title,
          detail = item.detail,
          trailing = item.trailing,
          selected = item.id == props.value,
          onActivate = function()
            act.emit('onChange', item.id)
          end,
        })
      end
      return { rows, children }
    end,
  })

  service:registerKind(owner, {
    name = 'lunette/table-header',
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'row',
          alignItems = 'center',
          gap = theme.spacing.md,
          minHeight = theme.sizes.section,
          padding = { left = theme.spacing.md, right = theme.spacing.md },
        }
      end,
    },
    visuals = { 'lunette/table-header' },
  })
  service:registerVisual(owner, 'lunette/table-header', function(node: uiHost.Node, draw: uiHost.Draw)
    draw:box(nil, { fill = node.theme.colors.section, radius = node.theme.radii.control })
  end)

  -- Table props: columns ({ id, label }), rows ({ id, cells }), value, and onChange.
  constructors.Table = service:registerKind(owner, {
    name = 'lunette/table',
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
      local columns = props.columns or {}
      local labels: { string } = {}
      for index, column in columns do
        labels[index] = string.upper(column.label)
      end
      local rows = {}
      for _, row in props.rows or {} do
        local selected = row.id == props.value
        rows[#rows + 1] = element('lunette/row-face', {
          key = uiHost.keyOf(row.id),
          selected = selected,
          compact = true,
          onActivate = function()
            act.emit('onChange', row.id)
          end,
          cells(columns, row.cells, 'body', if selected then 'accentInk' else 'ink'),
        })
      end
      return {
        element('lunette/table-header', { key = 'header', cells(columns, labels, 'section', 'sectionInk') }),
        rows,
      }
    end,
  })

  -- Tabs props: tabs (options), value, and onChange. The child whose key is the value is shown.
  constructors.Tabs = service:registerKind(owner, {
    name = 'lunette/tabs',
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return { flexDirection = 'column', alignItems = 'stretch', gap = theme.spacing.md, grow = props.grow }
      end,
    },
    expand = function(
      props: uiHost.Props,
      children: { read [number]: uiHost.Element },
      _state: { read [string]: any },
      act: uiHost.Actions
    ): uiHost.Child
      local strip = {}
      for _, tab in props.tabs or {} do
        local selected = tab.id == props.value
        strip[#strip + 1] = element('lunette/segment', {
          key = uiHost.keyOf(tab.id),
          selected = selected,
          onActivate = function()
            act.emit('onChange', tab.id)
          end,
          element('lunette/text', {
            key = 'label',
            text = tab.label,
            style = 'label',
            color = if selected then 'ink' else 'muted',
            wrap = false,
          }),
        })
      end
      local shown = nil
      for _, child in children do
        if child.key == uiHost.keyOf(props.value or '') then
          shown = child
        end
      end
      return {
        element('lunette/row', { key = 'strip', gap = 'xs', strip }),
        element('lunette/separator', { key = 'rule' }),
        shown,
      }
    end,
  })

  return constructors
end

return collections
