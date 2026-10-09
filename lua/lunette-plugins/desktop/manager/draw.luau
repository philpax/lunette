-- Draws the manager in logical pixels on the caller's transformed pass, without retaining resources or view state.

local theme = require '@lunette-contracts/theme'
local ui = require '@lunette-contracts/ui'
local graph = require './graph'
local view = require './view'
local geometry = require './graph-geometry'
local draw = {}
local DETAIL_DEPTH = 0.001

export type Button = {
  read x: number,
  read y: number,
  read width: number,
  read height: number,
  read label: string,
  read enabled: boolean,
}
export type Row = {
  read x: number,
  read y: number,
  read width: number,
  read height: number,
  read label: string,
  read value: string,
  read selected: boolean,
  read editable: boolean,
}
export type Options = {
  read width: number,
  read height: number,
  read sidebar: number,
  read details: { string },
  read wrappedDetails: boolean?,
  read detailsTop: number?,
  read buttons: { read [number]: Button },
  read rows: { Row },
  read footer: string,
}

export type SidebarPart = 'background' | 'details' | 'rows' | 'footer'

export type Style = { read theme: theme.Theme, read visual: ui.Theme }

local renderGraph: (Pass, Style, view.State, graph.Box, graph.Box?) -> ()
local renderSidebar: (Pass, Style, Options, graph.Box, SidebarPart?) -> ()
local renderButtons: (Pass, Style, { read [number]: Button }, graph.Box) -> ()
local intersect: (graph.Box, graph.Box) -> graph.Box?
local rectangle: (Pass, graph.Box, graph.Box, boolean?) -> ()
local segment: (Pass, graph.Point, graph.Point, graph.Box) -> ()
local textBox: (Pass, Font, string, graph.Box, graph.Box, number) -> boolean
local nodeColor: (graph.Node, theme.Colors) -> theme.Color
local validSize: (number) -> boolean
local wrappedTextBox: (Pass, Font, { string }, graph.Box, graph.Box, number) -> boolean

function draw.wrapDetails(font: Font, records: { string }, sidebar: number, size: number): { string }
  return font:getLines(table.concat(records, '\n'), (sidebar - 24) * math.max(font:getHeight(), 0.000001) / size)
end

function draw.render(pass: Pass, state: view.State, options: Options, style: Style): ()
  assert(validSize(options.width) and options.width > 0, 'manager drawing: width must be positive and finite')
  assert(validSize(options.height) and options.height > 0, 'manager drawing: height must be positive and finite')
  assert(validSize(options.sidebar) and options.sidebar <= options.width, 'manager drawing: invalid sidebar width')
  assert(validSize(state.viewport.x) and validSize(state.viewport.y), 'manager drawing: invalid graph viewport')
  assert(options.detailsTop == nil or validSize(options.detailsTop), 'manager drawing: invalid details top')
  if options.sidebar == 0 then
    assert(
      #options.details == 0 and #options.rows == 0 and options.footer == '',
      'manager drawing: sidebar content needs a sidebar'
    )
  end
  if options.sidebar > 0 and (table.concat(options.details, '\n') ~= '' or #options.rows == 0) then
    assert(options.sidebar > 24, 'manager drawing: details need a sidebar wider than 24 pixels')
    assert(
      (options.detailsTop or 12) < options.height - math.min(56, options.height / 3) - 8,
      'manager drawing: details need vertical room in the sidebar'
    )
  end
  for _, button in options.buttons do
    assert(validSize(button.width) and validSize(button.height), 'manager drawing: invalid button size')
    assert(
      math.abs(button.x) < math.huge and math.abs(button.y) < math.huge,
      'manager drawing: invalid button position'
    )
  end
  for _, row in options.rows do
    assert(validSize(row.width) and validSize(row.height), 'manager drawing: invalid row size')
    assert(math.abs(row.x) < math.huge and math.abs(row.y) < math.huge, 'manager drawing: invalid row position')
  end
  local bounds: graph.Box = { x = 0, y = 0, width = options.width, height = options.height }
  local canvas: graph.Box = {
    x = 0,
    y = 0,
    width = math.min(state.viewport.x, options.width - options.sidebar),
    height = math.min(state.viewport.y, options.height),
  }
  local font = style.visual.font
  local pushedState, pushedTransform = false, false
  local ok, message = pcall(function()
    pass:push 'state'
    pushedState = true
    pass:push 'transform'
    pushedTransform = true
    pass:setShader()
    pass:setMaterial(nil)
    pass:setFont(font)
    pass:setCullMode 'none'
    pass:setDepthTest 'gequal'
    pass:setDepthWrite(true)
    pass:setColor(style.visual.background)
    pass:translate(0, 0, -DETAIL_DEPTH)
    rectangle(pass, bounds, bounds)
    pass:translate(0, 0, DETAIL_DEPTH)
    pass:setDepthWrite(false)
    renderGraph(pass, style, state, canvas)
    renderSidebar(pass, style, options, bounds)
    renderButtons(pass, style, options.buttons, bounds)
  end)
  -- Attempt both pops even if one raises, without replacing the drawing error.
  if pushedTransform then
    local restored, restoreError = pcall(pass.pop, pass, 'transform')
    if ok and not restored then
      ok, message = false, restoreError
    end
  end
  if pushedState then
    local restored, restoreError = pcall(pass.pop, pass, 'state')
    if ok and not restored then
      ok, message = false, restoreError
    end
  end
  if not ok then
    error(message, 0)
  end
end

function draw.graph(pass: Pass, state: view.State, bounds: graph.Box, style: Style, clip: graph.Box?): ()
  renderGraph(pass, style, state, bounds, clip)
end

export type SidebarGeometry = {
  read background: graph.Box,
  read details: graph.Box,
  read footer: graph.Box,
}

function draw.sidebarGeometry(options: Options): SidebarGeometry
  local footerHeight = math.min(56, options.height / 3)
  local bottom = options.height - footerHeight
  local detailsTop = options.detailsTop or 12
  local detailsBottom = bottom - 8
  for _, row in options.rows do
    if row.y >= detailsTop then
      detailsBottom = math.min(detailsBottom, row.y - 8)
    end
  end
  for _, button in options.buttons do
    if button.x + button.width > options.width - options.sidebar and button.y >= detailsTop and button.y < bottom then
      detailsBottom = math.min(detailsBottom, button.y - 8)
    end
  end
  local left = options.width - options.sidebar
  return {
    background = { x = left, y = 0, width = options.sidebar, height = options.height },
    details = {
      x = left + 12,
      y = detailsTop,
      width = options.sidebar - 24,
      height = math.max(0, detailsBottom - detailsTop),
    },
    footer = { x = left, y = bottom, width = options.sidebar, height = footerHeight },
  }
end

function draw.details(pass: Pass, options: Options, clip: graph.Box, part: SidebarPart, style: Style): ()
  renderSidebar(pass, style, options, clip, part)
end

-- Later buttons take precedence where rectangles overlap. Disabled and zero-area buttons do not receive clicks.
function draw.hit(buttons: { read [number]: Button }, point: graph.Point): number?
  for index = #buttons, 1, -1 do
    local button = buttons[index]
    if
      button.enabled
      and button.width > 0
      and button.height > 0
      and point.x >= button.x
      and point.x < button.x + button.width
      and point.y >= button.y
      and point.y < button.y + button.height
    then
      return index
    end
  end
  return nil
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

renderGraph = function(pass: Pass, style: Style, state: view.State, bounds: graph.Box, clip: graph.Box?): ()
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

renderSidebar = function(pass: Pass, style: Style, options: Options, bounds: graph.Box, part: SidebarPart?): ()
  local font, colors, typography = style.visual.font, style.theme.colors, style.theme.typography
  local sidebar: graph.Box = {
    x = options.width - options.sidebar,
    y = 0,
    width = options.sidebar,
    height = options.height,
  }
  if sidebar.width == 0 then
    return
  end
  if part == nil or part == 'background' then
    pass:setColor(colors.elevatedBackground)
    rectangle(pass, sidebar, bounds)
  end
  if part == 'background' then
    return
  end
  local footerHeight = math.min(56, sidebar.height / 3)
  local body: graph.Box = { x = sidebar.x, y = 0, width = sidebar.width, height = sidebar.height - footerHeight }
  local detailsTop = options.detailsTop or 12
  local detailsBottom = body.height - 8
  for _, row in options.rows do
    if row.y >= detailsTop then
      detailsBottom = math.min(detailsBottom, row.y - 8)
    end
  end
  for _, button in options.buttons do
    if intersect(button, body) and button.y >= detailsTop then
      detailsBottom = math.min(detailsBottom, button.y - 8)
    end
  end
  local rowClip = intersect(body, bounds)
  local outside = 0
  for _, row in options.rows do
    assert(validSize(row.width) and validSize(row.height), 'manager drawing: invalid row size')
    if not intersect(row, body) then
      outside += 1
      continue
    end
    if (part ~= nil and part ~= 'rows') or not rowClip then
      continue
    end
    pass:setColor(if row.selected then style.visual.selection else style.visual.control)
    rectangle(pass, row, rowClip)
    pass:setColor(if row.editable then style.visual.foreground else colors.mutedForeground)
    local label = row.label .. ': ' .. (if row.value == '' then '(empty)' else row.value)
    local textBounds: graph.Box = {
      x = row.x + 6,
      y = row.y + 4,
      width = math.max(0, row.width - 12),
      height = math.max(0, row.height - 8),
    }
    if not intersect(textBounds, body) then
      outside += 1
    end
    textBox(pass, font, label, textBounds, rowClip, style.visual.fontSize)
  end
  pass:setColor(style.visual.foreground)
  local details = table.concat(options.details, '\n')
  if details == '' and #options.rows == 0 then
    details = 'Select a plugin or relationship to inspect it.'
  end
  local detailsBox: graph.Box = {
    x = sidebar.x + 12,
    y = detailsTop,
    width = sidebar.width - 24,
    height = math.max(0, detailsBottom - detailsTop),
  }
  if (part == nil or part == 'details') and rowClip then
    if options.wrappedDetails and #options.details > 0 then
      wrappedTextBox(pass, font, options.details, detailsBox, rowClip, style.visual.fontSize)
    else
      textBox(pass, font, details, detailsBox, rowClip, style.visual.fontSize)
    end
  end
  if part == 'details' or part == 'rows' then
    return
  end
  local footer = options.footer
  if outside > 0 then
    footer = tostring(outside)
      .. ' rows outside the sidebar. Scroll to view them.'
      .. (if footer == '' then '' else '\n' .. footer)
  end
  if details ~= '' and detailsBottom <= detailsTop then
    footer = 'Details do not fit above the rows.\n' .. footer
  end
  local footerClip = intersect(sidebar, bounds)
  if footerClip then
    pass:setColor(style.visual.background)
    rectangle(pass, { x = sidebar.x, y = body.height, width = sidebar.width, height = footerHeight }, footerClip)
    pass:setColor(colors.mutedForeground)
    textBox(pass, font, footer, {
      x = sidebar.x + 8,
      y = body.height + 4,
      width = sidebar.width - 16,
      height = footerHeight - 8,
    }, footerClip, typography.smallSize)
  end
end

renderButtons = function(pass: Pass, style: Style, buttons: { read [number]: Button }, bounds: graph.Box): ()
  local font, colors = style.visual.font, style.theme.colors
  local outside = 0
  for _, button in buttons do
    assert(validSize(button.width) and validSize(button.height), 'manager drawing: invalid button size')
    if not intersect(button, bounds) then
      outside += 1
      continue
    end
    pass:setColor(if button.enabled then style.visual.control else style.visual.disabled)
    rectangle(pass, button, bounds)
    pass:setColor(if button.enabled then style.visual.foreground else colors.mutedForeground)
    local textBounds: graph.Box = {
      x = button.x + 5,
      y = button.y + 3,
      width = math.max(0, button.width - 10),
      height = math.max(0, button.height - 6),
    }
    if button.label ~= '' and not intersect(textBounds, bounds) then
      outside += 1
    end
    textBox(pass, font, button.label, textBounds, bounds, math.min(style.theme.typography.smallSize, 16))
  end
  if outside > 0 then
    pass:setColor(colors.warning)
    textBox(pass, font, tostring(outside) .. ' buttons outside the surface.', {
      x = 8,
      y = math.max(0, bounds.height - 28),
      width = bounds.width - 16,
      height = 24,
    }, bounds, style.theme.typography.smallSize)
  end
end

intersect = function(box: graph.Box, clip: graph.Box): graph.Box?
  local x, y = math.max(box.x, clip.x), math.max(box.y, clip.y)
  local right = math.min(box.x + box.width, clip.x + clip.width)
  local bottom = math.min(box.y + box.height, clip.y + clip.height)
  if right <= x or bottom <= y then
    return nil
  end
  return { x = x, y = y, width = right - x, height = bottom - y }
end

rectangle = function(pass: Pass, box: graph.Box, clip: graph.Box, outline: boolean?): ()
  local bounded = intersect(box, clip)
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
  local dx, dy = to.x - from.x, to.y - from.y
  local first, last = 0, 1
  local p = { -dx, dx, -dy, dy }
  local q = { from.x - clip.x, clip.x + clip.width - from.x, from.y - clip.y, clip.y + clip.height - from.y }
  for index = 1, 4 do
    if p[index] == 0 then
      if q[index] < 0 then
        return
      end
    elseif p[index] < 0 then
      first = math.max(first, q[index] / p[index])
    else
      last = math.min(last, q[index] / p[index])
    end
  end
  if last >= first and clip.width > 0 and clip.height > 0 then
    pass:line(from.x + first * dx, from.y + first * dy, 0, from.x + last * dx, from.y + last * dy, 0)
  end
end

textBox = function(pass: Pass, font: Font, text: string, box: graph.Box, clip: graph.Box, size: number): boolean
  if text == '' then
    return false
  end
  local bounded = intersect(box, clip)
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
  local bounded = intersect(box, clip)
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

validSize = function(value: number): boolean
  return value >= 0 and value < math.huge
end

return draw
