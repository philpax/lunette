-- The virtual list: a scrolling list whose rows exist only while they are near the visible part, so a list of
-- thousands of entries keeps a few dozen nodes. Rows are host elements from an item renderer, so the list is
-- framework-free, as the extension design asks of composites.

local lunette = require '@lunette'
local schema = require '@lunette-plugin/schema'
local uiHost = require '@lunette-contracts/ui-host'
local shapes = require './props'
local scrolling = require './scrolling'

local virtual = {}

local element = uiHost.element
local optional = schema.optional

-- Rows beyond each edge of the visible part that stay materialised, so a fast scroll does not show gaps.
local OVERSCAN = 4

-- The range of rows to materialise for a scroll offset, as first and last indices from one.
function virtual.range(count: number, rowHeight: number, height: number, offset: number): (number, number)
  if count <= 0 or rowHeight <= 0 then
    return 1, 0
  end
  local first = math.max(1, math.floor(offset / rowHeight) + 1 - OVERSCAN)
  local last = math.min(count, math.ceil((offset + height) / rowHeight) + OVERSCAN)
  return first, last
end

function virtual.register(service: uiHost.Service, owner: any): { [string]: uiHost.Constructor }
  local constructors: { [string]: uiHost.Constructor } = {}

  service:registerKind(owner, {
    name = 'lunette/virtual-slot',
    props = schema.object { top = schema.number(), height = schema.number() },
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        -- Rows keep clear of the scrollbar's gutter, which absolute insets would otherwise cover.
        return {
          position = 'absolute',
          top = props.top,
          left = 0,
          right = scrolling.gutter(theme),
          height = props.height,
          flexDirection = 'column',
          alignItems = 'stretch',
        }
      end,
    },
  })

  service:registerKind(owner, {
    name = 'lunette/virtual-spacer',
    props = schema.object { height = schema.number() },
    layout = {
      kind = 'leaf',
      style = function(props: uiHost.Props): lunette.LayoutStyle
        return { height = props.height, width = '100%' }
      end,
    },
  })

  -- The height of every row, materialised or not.
  -- The list's scrollbar. A composite kind cannot draw, so the bar is a leaf over the list's right edge that draws
  -- the list's scroll state. It sits at the scroll offset, which the host subtracts again, so it stays in view; it
  -- takes no input, so presses on it reach the list, which handles the bar from its own geometry.
  service:registerKind(owner, {
    name = 'lunette/virtual-scrollbar',
    props = schema.object {
      offset = schema.number(),
      extent = schema.number(),
      active = optional(schema.boolean()),
    },
    layout = {
      kind = 'leaf',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          position = 'absolute',
          top = props.offset,
          right = 0,
          width = scrolling.gutter(theme),
          height = '100%',
        }
      end,
    },
    visuals = { 'lunette/virtual-scrollbar' },
  })
  service:registerVisual(owner, 'lunette/virtual-scrollbar', function(node: uiHost.Node, draw: uiHost.Draw)
    local props = node.props
    scrolling.drawBar(draw, node.theme, node.bounds, props.offset, props.extent, props.active == true)
  end)

  local function extent(node: uiHost.Node): number
    return (node.props.count or 0) * (node.state.rowHeight or 0)
  end

  -- VirtualList props: count, renderItem (index to an element with a key), rowHeight (metres or a size token),
  -- height, and grow.
  constructors.VirtualList = service:registerKind(owner, {
    name = 'lunette/virtual-list',
    props = schema.object {
      count = schema.number { minimum = 0 },
      renderItem = schema.callback(function(_index: number): any
        return nil
      end),
      rowHeight = optional(shapes.length),
      height = optional(shapes.length),
      grow = optional(schema.number()),
    },
    role = 'list',
    semantics = function(props: uiHost.Props, _state: { read [string]: any }): uiHost.Semantics
      return { value = props.count }
    end,
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props): lunette.LayoutStyle
        return {
          display = 'block',
          position = 'relative',
          height = props.height,
          grow = props.grow,
          shrink = 1,
          minHeight = 0,
          overflow = 'scroll',
        }
      end,
    },
    clip = true,
    state = { scrollY = 0, rowHeight = false, thumbDrag = false },
    claims = { drag = 'y' },
    interactive = function(): boolean
      return true
    end,
    event = function(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ())
      if not scrolling.event(node, event, extent(node)) then
        base(node, event)
      end
    end,
    expand = function(
      props: uiHost.Props,
      _children: { read [number]: uiHost.Element },
      state: { read [string]: any },
      actions: uiHost.Actions
    ): uiHost.Child
      local count = math.floor(props.count or 0)
      local rowHeight = if type(props.rowHeight) == 'number' then props.rowHeight else nil
      if rowHeight == nil then
        rowHeight = state.rowHeight or 0.036
      end
      -- The visible height is the box's own once laid out; until then, the height prop or a few rows.
      local visible = if type(props.height) == 'number' then props.height else rowHeight * 10
      if state.rowHeight ~= rowHeight then
        actions.setState { rowHeight = rowHeight }
      end
      local first, last = virtual.range(count, rowHeight, visible, state.scrollY or 0)
      local rows: { uiHost.Child } = {}
      for index = first, last do
        local item = props.renderItem(index)
        rows[#rows + 1] = element('lunette/virtual-slot', {
          key = `row-{index}`,
          top = (index - 1) * rowHeight,
          height = rowHeight,
          item,
        })
      end
      return {
        element('lunette/virtual-spacer', { key = 'extent', height = count * rowHeight }),
        element('lunette/virtual-scrollbar', {
          key = 'scrollbar',
          offset = state.scrollY or 0,
          extent = count * rowHeight,
          active = state.thumbDrag == true,
        }),
        rows,
      }
    end,
  })

  return constructors
end

return virtual
