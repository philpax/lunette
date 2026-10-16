-- Vertical scrolling shared by the scroll box and the virtual list: the wheel, dragging the content, and a scrollbar
-- whose thumb drags and whose track jumps. The host offsets a scrolling node's children by its scrollY state; a kind
-- reports the height of its content, since a virtual list's rows do not all exist.

local uiHost = require '@lunette-contracts/ui-host'

local scrolling = {}

-- Scroll arrives in logical pixels, positive downward; a pixel moves the content a millimetre.
local SCROLL_METRES = 0.001

-- The scrollbar's position along the node's right edge, in node coordinates.
export type Bar = {
  -- The left edge of the region that grabs the bar: the gutter the content keeps clear for it.
  read grab: number,
  read thumbY: number,
  read thumbHeight: number,
  -- How far the thumb travels from the top of the track to the bottom.
  read travel: number,
}

-- The width the content keeps clear at the right for the bar, so the bar is grabbed rather than the content.
function scrolling.gutter(theme: uiHost.Theme): number
  return theme.sizes.scrollbar * 3
end

-- The furthest the content scrolls, from the height of all of it.
local function limit(node: uiHost.Node, extent: number): number
  return math.max(extent - node.bounds.height, 0)
end

function scrolling.clamp(node: uiHost.Node, extent: number, offset: number): number
  return math.clamp(offset, 0, limit(node, extent))
end

-- The bar for content of a height, or nil when it all fits.
function scrolling.bar(node: uiHost.Node, extent: number): Bar?
  local height = node.bounds.height
  if extent <= height + 1e-6 then
    return nil
  end
  local theme = node.theme
  local thumbHeight = math.max(height * height / extent, theme.sizes.control)
  local travel = math.max(height - thumbHeight, 0)
  local progress = math.clamp((node.state.scrollY or 0) / limit(node, extent), 0, 1)
  return {
    grab = node.bounds.width - scrolling.gutter(theme),
    thumbY = travel * progress,
    thumbHeight = thumbHeight,
    travel = travel,
  }
end

-- Handles a scrolling node's events: the wheel scrolls, a drag on the content moves it with the pointer, a drag on the
-- bar moves the thumb with the pointer, and a press on the track beside the thumb brings the thumb to it. Answers
-- whether the event was consumed; a press is also left to the kind's default handling.
function scrolling.event(node: uiHost.Node, event: uiHost.Event, extent: number): boolean
  local kind = event.kind
  local any = event :: any
  local function scrollTo(offset: number): ()
    node:setState { scrollY = scrolling.clamp(node, extent, offset) }
  end
  if kind == 'scroll' then
    scrollTo((node.state.scrollY or 0) + any.dy * SCROLL_METRES)
    return true
  end
  local bar = scrolling.bar(node, extent)
  if kind == 'press' then
    if bar and any.x >= bar.grab and (any.y < bar.thumbY or any.y > bar.thumbY + bar.thumbHeight) then
      local progress = if bar.travel > 0 then (any.y - bar.thumbHeight / 2) / bar.travel else 0
      scrollTo(math.clamp(progress, 0, 1) * limit(node, extent))
    end
    return false
  elseif kind == 'drag-start' then
    node:setState { thumbDrag = bar ~= nil and any.x >= bar.grab }
    return true
  elseif kind == 'drag' then
    if node.state.thumbDrag and bar and bar.travel > 0 then
      scrollTo((node.state.scrollY or 0) + any.dy * limit(node, extent) / bar.travel)
    else
      scrollTo((node.state.scrollY or 0) - any.dy)
    end
    return true
  elseif kind == 'drag-end' then
    node:setState { thumbDrag = false }
    return true
  end
  return kind == 'hover-enter' or kind == 'hover-leave'
end

-- Draws the bar along the right edge of an area of a width and height: a rail, and a thumb that stands off it and
-- widens while the area is active.
function scrolling.drawBar(
  draw: uiHost.Draw,
  theme: uiHost.Theme,
  area: { read width: number, read height: number },
  offset: number,
  extent: number,
  active: boolean
): ()
  local height = area.height
  if extent <= height + 1e-6 then
    return
  end
  local width = theme.sizes.scrollbar
  local thumbHeight = math.max(height * height / extent, theme.sizes.control)
  local travel = math.max(height - thumbHeight, 0)
  local thumbY = travel * math.clamp(offset / (extent - height), 0, 1)
  draw:box({ x = area.width - width, y = 0, width = width, height = height }, { fill = theme.colors.rail })
  local thumbWidth = if active then width * 2 else width
  draw:box({ x = area.width - thumbWidth, y = thumbY, width = thumbWidth, height = thumbHeight }, {
    fill = if active then theme.colors.accent else theme.colors.muted,
    radius = theme.radii.control,
    offset = if active then theme.elevation.raised else theme.elevation.minimumSeparation,
    side = theme.colors.side,
  })
end

-- Draws a scrolling node's bar over its own bounds, active while it is hovered or its thumb is dragged.
function scrolling.draw(node: uiHost.Node, draw: uiHost.Draw, extent: number): ()
  local active = node.state.hovered == true or node.state.thumbDrag == true
  scrolling.drawBar(draw, node.theme, node.bounds, node.state.scrollY or 0, extent, active)
end

return scrolling
