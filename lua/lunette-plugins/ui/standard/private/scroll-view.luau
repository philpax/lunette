-- The scroll view: a clipped region that scrolls vertically, with a scrollbar whose thumb drags and whose track jumps.
-- Its content is either its children, laid out in full, or a run of items it materialises only near the visible part,
-- so a list of thousands of entries keeps a few dozen nodes. The host offsets a scrolling node's children by its
-- scrollY state and does not pack nodes that lie wholly outside a clip, so off-screen children cost layout only.

local lunette = require '@lunette'
local schema = require '@lunette-plugin/schema'
local uiHost = require '@lunette-contracts/ui-host'
local shapes = require './props'

local scrollView = {}

local element = uiHost.element
local optional = schema.optional

-- Scroll arrives in logical pixels, positive downward; a pixel moves the content a millimetre.
local SCROLL_METRES = 0.001
-- Items beyond each edge of the visible part that stay materialised, so a fast scroll does not show gaps.
local OVERSCAN = 4
-- An item's height when none is given.
local DEFAULT_ROW = 0.036
-- The rows assumed visible before the view has been measured, so a tall view does not open with missing rows.
local UNMEASURED_ROWS = 24

-- The range of items to materialise for a scroll offset, as first and last indices from one.
function scrollView.range(count: number, rowHeight: number, height: number, offset: number): (number, number)
  if count <= 0 or rowHeight <= 0 then
    return 1, 0
  end
  local first = math.max(1, math.floor(offset / rowHeight) + 1 - OVERSCAN)
  local last = math.min(count, math.ceil((offset + height) / rowHeight) + OVERSCAN)
  return first, last
end

-- The width the content keeps clear at the right for the bar, so a press there grabs the bar rather than the content.
local function gutter(theme: uiHost.Theme): number
  return theme.sizes.scrollbar * 3
end

-- The height of all the content: the children's, or every item's, which a spacer gives the items mode.
local function extent(node: uiHost.Node): number
  local _, height = node:contentSize()
  return height
end

local function limit(node: uiHost.Node): number
  return math.max(extent(node) - node.bounds.height, 0)
end

-- The scrollbar's thumb in node coordinates, or nil when the content fits.
type Bar = {
  -- The left edge of the gutter that grabs the bar.
  read grab: number,
  read thumbY: number,
  read thumbHeight: number,
  -- How far the thumb travels from the top of the track to the bottom.
  read travel: number,
}

local function bar(node: uiHost.Node): Bar?
  local height = node.bounds.height
  local total = extent(node)
  if total <= height + 1e-6 then
    return nil
  end
  local thumbHeight = math.max(height * height / total, node.theme.sizes.control)
  local travel = math.max(height - thumbHeight, 0)
  return {
    grab = node.bounds.width - gutter(node.theme),
    thumbY = travel * math.clamp((node.state.scrollY or 0) / (total - height), 0, 1),
    thumbHeight = thumbHeight,
    travel = travel,
  }
end

-- The wheel scrolls, a drag on the content moves it with the pointer, a drag on the bar moves the thumb with the
-- pointer, and a press on the track beside the thumb brings the thumb to it. The view also notes its visible height
-- when an interaction reaches it, so the items mode materialises enough rows.
local function event(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ()): ()
  local kind = event.kind
  local any = event :: any
  local function scrollTo(offset: number): ()
    local height = node.bounds.height
    node:setState {
      scrollY = math.clamp(offset, 0, limit(node)),
      viewHeight = if height > 0 then height else node.state.viewHeight,
    }
  end
  local current = node.state.scrollY or 0
  local found = bar(node)
  if kind == 'scroll' then
    scrollTo(current + any.dy * SCROLL_METRES)
  elseif kind == 'press' then
    if found and any.x >= found.grab and (any.y < found.thumbY or any.y > found.thumbY + found.thumbHeight) then
      local progress = if found.travel > 0 then (any.y - found.thumbHeight / 2) / found.travel else 0
      scrollTo(math.clamp(progress, 0, 1) * limit(node))
    end
    base(node, event)
  elseif kind == 'drag-start' then
    node:setState { thumbDrag = found ~= nil and any.x >= found.grab }
  elseif kind == 'drag' then
    if node.state.thumbDrag and found and found.travel > 0 then
      scrollTo(current + any.dy * limit(node) / found.travel)
    else
      scrollTo(current - any.dy)
    end
  elseif kind == 'drag-end' then
    node:setState { thumbDrag = false }
  elseif kind == 'hover-enter' then
    scrollTo(current)
  elseif kind ~= 'hover-leave' then
    base(node, event)
  end
end

function scrollView.register(service: uiHost.Service, owner: any): { [string]: uiHost.Constructor }
  local constructors: { [string]: uiHost.Constructor } = {}

  service:registerKind(owner, {
    name = 'lunette/scroll-item',
    props = schema.object { top = schema.number(), height = schema.number() },
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        -- Absolute insets ignore the view's padding, so an item keeps clear of the bar's gutter itself.
        return {
          position = 'absolute',
          top = props.top,
          left = 0,
          right = gutter(theme),
          height = props.height,
          flexDirection = 'column',
          alignItems = 'stretch',
        }
      end,
    },
  })

  service:registerKind(owner, {
    name = 'lunette/scroll-extent',
    props = schema.object { height = schema.number() },
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props): lunette.LayoutStyle
        return { height = props.height, width = '100%' }
      end,
    },
  })

  -- ScrollView props: height, maxHeight, grow, and bleed, which reaches through the panel body's side padding so
  -- section bands inside reach the panel's edges. Its content is its children, or, given count and renderItem (an
  -- index to an element with a key), that many items of rowHeight metres, materialised only near the visible part.
  constructors.ScrollView = service:registerKind(owner, {
    name = 'lunette/scroll-view',
    props = schema.object {
      height = optional(shapes.length),
      maxHeight = optional(shapes.length),
      grow = optional(schema.number()),
      bleed = optional(schema.boolean()),
      count = optional(schema.number { minimum = 0 }),
      renderItem = optional(schema.callback(function(_index: number): any
        return nil
      end)),
      rowHeight = optional(schema.number { positive = true }),
    },
    role = 'scrollbar',
    semantics = function(props: uiHost.Props, _state: { read [string]: any }): uiHost.Semantics
      return { value = props.count }
    end,
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        -- Block layout keeps children at their own heights rather than shrinking them to the view.
        return {
          display = 'block',
          position = 'relative',
          height = props.height,
          maxHeight = props.maxHeight,
          grow = props.grow,
          shrink = 1,
          minHeight = 0,
          overflow = 'scroll',
          padding = if props.bleed
            then { left = theme.spacing.lg, right = math.max(theme.spacing.lg, gutter(theme)) }
            else { right = gutter(theme) },
          margin = if props.bleed then { left = -theme.spacing.lg, right = -theme.spacing.lg } else nil,
        }
      end,
    },
    clip = true,
    state = { scrollY = 0, thumbDrag = false, viewHeight = false },
    claims = { drag = 'y' },
    interactive = function(): boolean
      return true
    end,
    visuals = { 'lunette/scroll-view' },
    event = event,
    expand = function(
      props: uiHost.Props,
      children: { read [number]: uiHost.Element },
      state: { read [string]: any }
    ): uiHost.Child
      local renderItem = props.renderItem :: ((number) -> uiHost.Child)?
      if renderItem == nil then
        return children
      end
      local count = math.floor(props.count or 0)
      local rowHeight = props.rowHeight or DEFAULT_ROW
      local visible = if state.viewHeight
        then state.viewHeight
        elseif type(props.height) == 'number' then props.height
        else rowHeight * UNMEASURED_ROWS
      local first, last = scrollView.range(count, rowHeight, visible, state.scrollY or 0)
      local rows: { uiHost.Child } = {}
      for index = first, last do
        rows[#rows + 1] = element('lunette/scroll-item', {
          key = `row-{index}`,
          top = (index - 1) * rowHeight,
          height = rowHeight,
          renderItem(index),
        })
      end
      return {
        element('lunette/scroll-extent', { key = 'extent', height = count * rowHeight }),
        rows,
      }
    end,
  })
  -- The bar: a rail along the right edge, and a thumb that stands off it and widens while the view is hovered or its
  -- thumb is dragged.
  service:registerVisual(owner, 'lunette/scroll-view', function(node: uiHost.Node, draw: uiHost.Draw)
    local found = bar(node)
    if not found then
      return
    end
    local theme = node.theme
    local bounds = node.bounds
    local width = theme.sizes.scrollbar
    draw:box({ x = bounds.width - width, y = 0, width = width, height = bounds.height }, { fill = theme.colors.rail })
    local active = node.state.hovered == true or node.state.thumbDrag == true
    local thumbWidth = if active then width * 2 else width
    draw:box({ x = bounds.width - thumbWidth, y = found.thumbY, width = thumbWidth, height = found.thumbHeight }, {
      fill = if active then theme.colors.accent else theme.colors.muted,
      radius = theme.radii.control,
      offset = if active then theme.elevation.raised else theme.elevation.minimumSeparation,
      side = theme.colors.side,
    })
  end)

  return constructors
end

return scrollView
