-- Draws the manager in logical pixels on the caller's transformed pass, without retaining resources or view state.

local theme = require '@lunette-contracts/theme'
local ui = require '@lunette-contracts/ui'
local graph = require '../inspection/graph'
local view = require '../inspection/view'
local geometry = require '../inspection/graph-geometry'
local draw = {}
local DETAIL_DEPTH = 0.001

export type Options = {
  read width: number,
  read height: number,
  read sidebar: number,
  read details: { string },
  read wrappedDetails: boolean,
  read detailsTop: number,
  read body: graph.Box?,
  read footer: string,
}

export type SidebarPart = 'background' | 'details' | 'footer'

export type Style = { read theme: theme.Theme, read visual: ui.Theme }

local rectangle: (Pass, graph.Box, graph.Box, boolean?) -> ()
local segment: (Pass, graph.Point, graph.Point, graph.Box) -> ()
local textBox: (Pass, Font, string, graph.Box, graph.Box, number) -> boolean
local nodeColor: (graph.Node, theme.Colors) -> theme.Color
local wrappedTextBox: (Pass, Font, { string }, graph.Box, graph.Box, number) -> boolean

function draw.wrapDetails(font: Font, records: { string }, sidebar: number, size: number): { string }
  return font:getLines(table.concat(records, '\n'), (sidebar - 24) * math.max(font:getHeight(), 0.000001) / size)
end

export type SidebarGeometry = {
  read background: graph.Box,
  read details: graph.Box,
  read footer: graph.Box,
}

function draw.sidebarGeometry(options: Options): SidebarGeometry
  local footerHeight = math.min(56, options.height / 3)
  local bottom = options.height - footerHeight
  local detailsBottom = bottom - 8
  if options.body then
    detailsBottom = math.min(detailsBottom, options.body.y - 8)
  end
  local left = options.width - options.sidebar
  return {
    background = { x = left, y = 0, width = options.sidebar, height = options.height },
    details = {
      x = left + 12,
      y = options.detailsTop,
      width = options.sidebar - 24,
      height = math.max(0, detailsBottom - options.detailsTop),
    },
    footer = { x = left, y = bottom, width = options.sidebar, height = footerHeight },
  }
end

local function arrow(
  pass: Pass,
  state: view.State,
  edge: graph.Edge,
  points: { read [number]: graph.Point },
  clip: graph.Box
): ()
  if #points < 2 then
    return
  end
  local from, target = points[#points - 1], points[#points]
  local dx, dy = target.x - from.x, target.y - from.y
  local length = math.sqrt(dx * dx + dy * dy)
  if length == 0 then
    return
  end
  local ux, uy = dx / length, dy / length
  local inset = 0
  local box = state.layout[edge.to]
  if box and edge.from ~= edge.to then
    inset = math.min(
      if ux == 0 then math.huge else box.width * state.camera.zoom / (2 * math.abs(ux)),
      if uy == 0 then math.huge else box.height * state.camera.zoom / (2 * math.abs(uy))
    )
  end
  local tip: graph.Point = { x = target.x - ux * inset, y = target.y - uy * inset }
  local size = math.min(8, math.max(0, length - inset))
  segment(pass, tip, { x = tip.x - ux * size - uy * size / 2, y = tip.y - uy * size + ux * size / 2 }, clip)
  segment(pass, tip, { x = tip.x - ux * size + uy * size / 2, y = tip.y - uy * size - ux * size / 2 }, clip)
end

function draw.graph(pass: Pass, state: view.State, bounds: graph.Box, style: Style, clip: graph.Box?): ()
  local canvas = clip or bounds
  local font, colors, typography = style.visual.font, style.theme.colors, style.theme.typography
  local selection = state.selection
  local count, outside, clipped = 0, 0, 0
  local scene = geometry.project(state, bounds, canvas)
  for _, projected in scene.edges do
    local edge, points = projected.edge, projected.points
    local selected = selection ~= nil and selection.kind == 'edge' and selection.id == edge.id
    pass:setColor(
      if selected
        then style.visual.focus
        else if edge.kind == 'ownership' then colors.ownershipEdge else colors.dependencyEdge
    )
    for index = 1, #points - 1 do
      segment(pass, points[index], points[index + 1], canvas)
    end
    arrow(pass, state, edge, points, canvas)
    if #points >= 2 then
      local middle = points[math.ceil(#points / 2)]
      local label = edge.label .. (if edge.generation then ' [' .. edge.generation .. ']' else '')
      if
        textBox(
          pass,
          font,
          label,
          { x = middle.x + 5, y = middle.y + 5, width = 180, height = 32 },
          canvas,
          typography.smallSize
        )
      then
        clipped += 1
      end
    end
  end
  for _, projected in scene.nodes do
    local node, pixels = projected.node, projected.bounds
    count += 1
    if not projected.clipped then
      outside += 1
      continue
    end
    local selected = selection ~= nil and selection.kind == 'node' and selection.id == node.id
    pass:setColor(
      if node.state == 'failed' or node.state == 'quarantined' then colors.errorBackground else style.visual.control
    )
    rectangle(pass, pixels, canvas)
    pass:setColor(if selected then style.visual.focus else style.visual.border)
    rectangle(pass, pixels, canvas, true)
    pass:setColor(nodeColor(node, colors))
    local label = node.name .. '\n' .. node.state .. (if node.enabled then '' else ' (disabled)')
    if
      textBox(pass, font, label, {
        x = pixels.x + 5,
        y = pixels.y + 3,
        width = math.max(0, pixels.width - 10),
        height = math.max(0, pixels.height - 6),
      }, canvas, style.visual.fontSize * math.min(1, state.camera.zoom))
    then
      clipped += 1
    end
  end
  local message = if #state.snapshot.nodes == 0
    then 'No plugins in the graph.'
    else if count == 0 then 'No plugins match the current filter.' else ''
  if outside > 0 then
    message = tostring(outside) .. ' plugins outside the canvas. Pan or fit the graph.'
  end
  if clipped > 0 then
    message ..= (if message == '' then '' else '\n') .. tostring(clipped) .. ' labels clipped. Pan, zoom, or inspect the selection.'
  end
  if message ~= '' then
    pass:setColor(colors.mutedForeground)
    textBox(
      pass,
      font,
      message,
      { x = canvas.x + 12, y = canvas.y + 12, width = canvas.width - 24, height = 56 },
      canvas,
      style.visual.fontSize
    )
  end
end

function draw.details(pass: Pass, options: Options, clip: graph.Box, part: SidebarPart, style: Style): ()
  local font, colors = style.visual.font, style.theme.colors
  local boxes = draw.sidebarGeometry(options)
  if part == 'background' then
    pass:setColor(colors.elevatedBackground)
    rectangle(pass, boxes.background, clip)
    return
  end
  local details = table.concat(options.details, '\n')
  if details == '' and not options.body then
    details = 'Select a plugin or relationship to inspect it.'
  end
  if part == 'details' then
    pass:setColor(style.visual.foreground)
    if options.wrappedDetails and #options.details > 0 then
      wrappedTextBox(pass, font, options.details, boxes.details, clip, style.visual.fontSize)
    else
      textBox(pass, font, details, boxes.details, clip, style.visual.fontSize)
    end
    return
  end
  local footer = options.footer
  if details ~= '' and boxes.details.height <= 0 then
    footer = 'Details do not fit above the rows.\n' .. footer
  end
  local box = boxes.footer
  pass:setColor(style.visual.background)
  rectangle(pass, box, clip)
  pass:setColor(colors.mutedForeground)
  textBox(pass, font, footer, {
    x = box.x + 8,
    y = box.y + 4,
    width = box.width - 16,
    height = box.height - 8,
  }, clip, style.theme.typography.smallSize)
end

rectangle = function(pass: Pass, box: graph.Box, clip: graph.Box, outline: boolean?): ()
  local bounded = geometry.intersect(box, clip)
  if not bounded then
    return
  end
  if not outline then
    pass:plane(bounded.x + bounded.width / 2, bounded.y + bounded.height / 2, 0, bounded.width, bounded.height)
    return
  end
  local a, b = { x = box.x, y = box.y }, { x = box.x + box.width, y = box.y }
  local c, d = { x = box.x + box.width, y = box.y + box.height }, { x = box.x, y = box.y + box.height }
  segment(pass, a, b, clip)
  segment(pass, b, c, clip)
  segment(pass, c, d, clip)
  segment(pass, d, a, clip)
end

-- Clip before projection: a framebuffer scissor would not follow the XR surface's pose.
segment = function(pass: Pass, from: graph.Point, to: graph.Point, clip: graph.Box): ()
  local first, last = geometry.segment(from, to, clip)
  if first and last then
    pass:line(first.x, first.y, 0, last.x, last.y, 0)
  end
end

textBox = function(pass: Pass, font: Font, text: string, box: graph.Box, clip: graph.Box, size: number): boolean
  if text == '' then
    return false
  end
  local bounded = geometry.intersect(box, clip)
  if not bounded then
    return true
  end
  local scale = math.min(size, bounded.height) / math.max(font:getHeight(), 0.000001)
  return wrappedTextBox(pass, font, font:getLines(text, bounded.width / scale), box, clip, size)
end

wrappedTextBox = function(
  pass: Pass,
  font: Font,
  lines: { string },
  box: graph.Box,
  clip: graph.Box,
  size: number
): boolean
  local bounded = geometry.intersect(box, clip)
  if not bounded then
    return #lines > 0
  end
  local scale = math.min(size, bounded.height) / math.max(font:getHeight(), 0.000001)
  local leading = font:getHeight() * scale * math.max(1, font:getLineSpacing())
  local capacity = math.max(1, math.floor(bounded.height / leading))
  local overflow = #lines > capacity
  for index = 1, math.min(#lines, capacity) do
    local line = if overflow and index == capacity
      then '... (+' .. tostring(#lines - capacity + 1) .. ' lines)'
      else lines[index]
    local width = font:getWidth(line)
    local fitted = if width > 0 then math.min(scale, bounded.width / width) else scale
    -- LÖVR glyphs are y-up; the caller's logical pixel transform is y-down.
    pass:text(
      line,
      bounded.x,
      bounded.y + (index - 1) * leading,
      DETAIL_DEPTH,
      fitted,
      math.pi,
      1,
      0,
      0,
      0,
      'left',
      'top'
    )
  end
  return overflow
end

nodeColor = function(node: graph.Node, colors: theme.Colors): theme.Color
  if node.state == 'failed' or node.state == 'quarantined' then
    return colors.error
  elseif not node.enabled or node.state == 'inactive' or node.state == 'removed' then
    return colors.mutedForeground
  elseif node.state == 'blocked' or node.state == 'loading' or node.state == 'unloading' then
    return colors.warning
  elseif node.state == 'active' then
    return colors.success
  end
  return colors.foreground
end

return draw
