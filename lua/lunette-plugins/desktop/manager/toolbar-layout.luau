-- Defines the logical canvas shared by manager configuration, domain state, and UI controls.

local graph = require './graph'
local toolbarLayout = { minimumWidth = 800, minimumHeight = 472 }

export type Group = 'sidebar' | 'graph' | 'edit'
export type Placement = { read bounds: graph.Box, read group: Group }
export type Layout = {
  read buttons: { [string]: Placement },
  read graphBounds: graph.Box,
  read bodyBounds: graph.Box,
  read editBounds: graph.Box?,
  read searchBounds: graph.Box?,
  read detailsTop: number,
}

function toolbarLayout.sidebarWidth(width: number): number
  return math.min(440, width * 0.4)
end

function toolbarLayout.compute(
  width: number,
  height: number,
  editing: boolean,
  searching: boolean,
  valueField: ('boolean' | 'choice')?
): Layout
  assert(width >= toolbarLayout.minimumWidth and width < math.huge, 'manager layout: invalid logical width')
  assert(height >= toolbarLayout.minimumHeight and height < math.huge, 'manager layout: invalid logical height')
  local sidebar = toolbarLayout.sidebarWidth(width)
  local left = width - sidebar
  local buttons: { [string]: Placement } = {}
  local function group(ids: { string }, kind: Group, x: number, y: number, extent: number, columns: number): number
    local buttonWidth = (extent - (columns - 1) * 4) / columns
    for index, id in ids do
      buttons[id] = {
        bounds = {
          x = x + ((index - 1) % columns) * (buttonWidth + 4),
          y = y + math.floor((index - 1) / columns) * 30,
          width = buttonWidth,
          height = 26,
        },
        group = kind,
      }
    end
    return y + math.ceil(#ids / columns) * 30
  end
  local detailsTop = group({
    'inspect',
    'configure',
    'catalog',
    'enable',
    'disable',
    'reload',
    'recover',
    'remove',
    'apply',
    'optional',
    'reset',
    'add',
    'remove-value',
    'previous',
    'next',
    'load',
  }, 'sidebar', left + 10, 8, sidebar - 20, 3) + 10
  local graphTop = group({
    'zoom-in',
    'zoom-out',
    'focus',
    'fit',
    'search',
    'transitive',
    'providers',
    'consumers',
    'all',
    'affected',
    'clear-filter',
    'clear-selection',
    'close',
  }, 'graph', 8, 8, left - 16, 5) + 6
  local searchBounds: graph.Box? = nil
  if searching then
    searchBounds = { x = 8, y = graphTop, width = left - 16, height = 34 }
    graphTop += 42
  end
  local editBounds: graph.Box? = nil
  local bodyBottom = height - 64
  if editing or valueField then
    editBounds = { x = left + 10, y = height - 112, width = sidebar - 20, height = 34 }
    if editing then
      group({ 'confirm', 'cancel', 'clear' }, 'edit', left + 10, height - 72, sidebar - 20, 3)
    end
    bodyBottom = height - 120
    if not editing and valueField == 'choice' then
      editBounds = { x = left + 10, y = height - 158, width = sidebar - 20, height = 102 }
      bodyBottom = height - 166
    end
  end
  return {
    buttons = buttons,
    graphBounds = { x = 0, y = graphTop, width = left, height = height - graphTop },
    bodyBounds = { x = left + 10, y = detailsTop + 68, width = sidebar - 20, height = bodyBottom - detailsTop - 68 },
    editBounds = editBounds,
    searchBounds = searchBounds,
    detailsTop = detailsTop,
  }
end

return toolbarLayout
