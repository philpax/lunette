local testing = require '@testing'
local plugin = require '@lunette-plugin'
local frameContract = require '@lunette-contracts/frame'
local management = require '@lunette-plugin/management'
local controller = require '../controller'
local drawing = require '../draw'
local presets = require '@lunette-plugins/theme/presets'
local uiTheme = require '@lunette-plugins/ui/theme'
local draw = {
  hit = drawing.hit,
  wrapDetails = function(font, records, sidebar)
    return drawing.wrapDetails(font, records, sidebar, presets.BASE.typography.bodySize)
  end,
  render = function(pass, state, options)
    local visual = uiTheme.materialize(uiTheme.global(presets.BASE, 0), lovr.graphics.getDefaultFont())
    return drawing.render(pass, state, options, { theme = presets.BASE, visual = visual })
  end,
}
local graph = require '../graph'
local view = require '../view'
local expect = testing.expect
local test = testing.suite()

local function fixture()
  local fake = testing.native()
  local events = fake.events
  local font = {}
  function font:getHeight()
    return 1
  end
  function font:getLineSpacing()
    return 1
  end
  function font:getWidth(text)
    return utf8.len(text) * 0.5
  end
  function font:getLines(text, wrap)
    local lines = {}
    local limit = math.max(1, math.floor(wrap * 2))
    for line in (text .. '\n'):gmatch '(.-)\n' do
      local start, count = 1, 0
      for offset in utf8.codes(line) do
        if count == limit then
          lines[#lines + 1] = line:sub(start, offset - 1)
          start, count = offset, 0
        end
        count += 1
      end
      lines[#lines + 1] = line:sub(start)
    end
    return lines
  end
  lovr.graphics.getDefaultFont = function()
    return font
  end
  local pass = events.pass
  pass.stack = { state = 0, transform = 0 }
  pass.saved = { state = {}, transform = {} }
  pass.state, pass.transform = {}, {}
  function pass:push(kind)
    events.draw[#events.draw + 1] = { 'push', kind }
    table.insert(self.saved[kind], table.clone(self[kind]))
    self.stack[kind] += 1
  end
  function pass:pop(kind)
    events.draw[#events.draw + 1] = { 'pop', kind }
    expect.truthy(self.stack[kind] > 0, 'balanced stack')
    self[kind] = table.remove(self.saved[kind])
    self.stack[kind] -= 1
  end
  for _, method in { 'setShader', 'setMaterial', 'setFont', 'setCullMode', 'setDepthTest', 'setDepthWrite', 'setColor' } do
    pass[method] = function(self, ...)
      events.draw[#events.draw + 1] = { method, ... }
      self.state[method] = { ... }
    end
  end
  return fake, pass, font
end

local function options()
  return { width = 1000, height = 600, sidebar = 300, details = {}, rows = {}, buttons = {}, footer = '' }
end

local function snapshot()
  return {
    nodes = {
      { id = 'source', name = 'Source', state = 'active', enabled = true },
      { id = 'target', name = 'Target', state = 'blocked', enabled = true },
    },
    edges = {
      { id = 'dep', kind = 'dependency', from = 'source', to = 'target', label = 'service' },
      { id = 'owner', kind = 'ownership', from = 'source', to = 'target', label = 'owned' },
      { id = 'reverse', kind = 'dependency', from = 'target', to = 'source', label = 'reverse' },
      { id = 'loop', kind = 'dependency', from = 'source', to = 'source', label = 'loop' },
    },
  }
end

local function stateFor(data)
  local state = view.new { x = 700, y = 600 }
  view.update(state, data)
  state.layout = {
    source = { x = 100, y = 120, width = 180, height = 60 },
    target = { x = 400, y = 300, width = 180, height = 60 },
  }
  state.camera = { x = 0, y = 0, zoom = 1 }
  return state
end

local function hasText(events, fragment)
  for _, command in events.draw do
    if command[1] == 'text' and command[2]:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

local function lines(events)
  local result = {}
  for _, command in events.draw do
    if command[1] == 'line' then
      result[#result + 1] = command
    end
  end
  return result
end

local function equalSegment(command, from, to)
  expect.equal(command[1], 'line')
  expect.near(command[2], from.x, 0.00001, 'segment starts at route x')
  expect.near(command[3], from.y, 0.00001, 'segment starts at route y')
  expect.equal(command[4], 0, 'logical plane')
  expect.near(command[5], to.x, 0.00001, 'segment ends at route x')
  expect.near(command[6], to.y, 0.00001, 'segment ends at route y')
  expect.equal(command[7], 0, 'logical plane')
end

for _, multiline in { false, true } do
  test('scrolling reaches a long ' .. (if multiline then 'multiline' else 'wrapped') .. ' diagnostic tail', function()
    local fake, pass, font = fixture()
    local marker = 'DIAGNOSTIC_TAIL_MARKER'
    local message = string.rep(if multiline then 'trace line\n' else 'diagnostic words ', 240) .. '\n' .. marker
    local definition = plugin.define {
      name = 'manager-long-diagnostic',
      init = function()
        error(message, 0)
      end,
    }
    local running = management.start { { id = 'failure', definition = definition } }
    testing.takeReports()
    local selected = running.service:entries()[2]
    local state = controller.new(running.service, {}, 1000, 600, function(records, sidebar)
      return draw.wrapDetails(font, records, sidebar)
    end)
    state.view.selection = { kind = 'node', id = selected.instanceId }
    controller.update(state)
    draw.render(pass, state.view, controller.options(state))
    expect.equal(hasText(fake.events, marker), false, 'the tail starts outside the visible body')
    local seen = false
    for _ = 1, 600 do
      controller.scrollBy(state, 1)
      table.clear(fake.events.draw)
      draw.render(pass, state.view, controller.options(state))
      if hasText(fake.events, marker) then
        seen = true
        break
      end
    end
    expect.equal(seen, true, 'scrolling reaches the diagnostic tail')
    state.scroll = 0
    controller.update(state)
    local last = state.lines[#state.lines]
    local lastIndex = #state.lines - 1
    for _ = 1, lastIndex + 10 do
      controller.scrollBy(state, 1)
    end
    expect.equal(state.scroll, lastIndex, 'arrow scrolling reaches the final record')
    table.clear(fake.events.draw)
    draw.render(pass, state.view, controller.options(state))
    expect.equal(hasText(fake.events, last), true, 'the final record is rendered')
    controller.scrollBy(state, -1)
    expect.equal(state.scroll, math.max(0, lastIndex - 1), 'scrolling also returns from the end')
    running.runtime:close()
  end)
end

test('draws the shared route for parallel, reversed, and self-loop edges at multiple camera scales', function()
  for _, zoom in { 0.5, 1, 1.1 } do
    local fake, pass = fixture()
    local state = stateFor(snapshot())
    state.camera = { x = -15, y = -20, zoom = zoom }
    draw.render(pass, state, options())
    local commands = lines(fake.events)
    local cursor = 1
    for _, edge in state.snapshot.edges do
      local route = graph.route(state.snapshot, state.layout, state.camera, edge)
      for index = 1, #route - 1 do
        equalSegment(
          commands[cursor],
          graph.screen(state.camera, route[index]),
          graph.screen(state.camera, route[index + 1])
        )
        cursor += 1
      end
      local left, right = commands[cursor], commands[cursor + 1]
      expect.equal(left[2], right[2], 'arrow wings share a tip')
      expect.equal(left[3], right[3], 'arrow wings share a tip')
      expect.truthy(left[2] ~= left[5] or left[3] ~= left[6], 'non-degenerate arrow')
      cursor += 2
    end
    expect.truthy(hasText(fake.events, 'service'))
    expect.truthy(hasText(fake.events, 'loop'))
    expect.equal(pass.stack.state, 0)
    expect.equal(pass.stack.transform, 0)
    expect.equal(state.camera.zoom, zoom, 'does not change camera')
  end
end)

test('draws an ordinary edge and places its direction arrow at the target boundary', function()
  local fake, pass = fixture()
  local data = snapshot()
  data.edges = { data.edges[1] }
  local state = stateFor(data)
  draw.render(pass, state, options())
  local commands = lines(fake.events)
  local route = graph.route(data, state.layout, state.camera, data.edges[1])
  equalSegment(commands[1], route[1], route[2])
  equalSegment(commands[2], route[2], route[3])
  expect.near(commands[3][3], 300, 0.00001, 'arrow reaches target top edge')
  expect.truthy(commands[3][2] >= 400 and commands[3][2] <= 580, 'arrow lies on target boundary')
end)

test('clips all graph geometry in logical coordinates without a framebuffer scissor', function()
  local fake, pass = fixture()
  local state = stateFor(snapshot())
  state.camera = { x = 230, y = 170, zoom = 4 }
  state.viewport = { x = 420, y = 330 }
  draw.render(pass, state, options())
  for _, command in fake.events.draw do
    expect.truthy(command[1] ~= 'setScissor', 'does not use framebuffer pixels')
    if command[1] == 'line' then
      for _, index in { 2, 5 } do
        expect.truthy(command[index] >= 0 and command[index] <= 420, 'line x within graph')
        expect.truthy(command[index + 1] >= 0 and command[index + 1] <= 330, 'line y within graph')
      end
    elseif command[1] == 'plane' and command[2] < 700 and command[5] ~= 1000 then
      expect.truthy(command[2] - command[5] / 2 >= 0, 'clipped plane left')
      expect.truthy(command[2] + command[5] / 2 <= 420, 'clipped plane right')
      expect.truthy(command[3] - command[6] / 2 >= 0, 'clipped plane top')
      expect.truthy(command[3] + command[6] / 2 <= 330, 'clipped plane bottom')
    elseif command[1] == 'text' then
      expect.truthy(command[3] >= 0 and command[3] <= 1000, 'text x within surface')
      expect.truthy(command[4] >= 0 and command[4] <= 600, 'text y within surface')
      expect.equal(command[5], 0.001, 'text sits in front of its logical face')
      expect.equal(command[7], math.pi, 'glyphs face upright in the y-down canvas')
    end
  end
  table.clear(fake.events.draw)
  state.camera = { x = 0, y = 0, zoom = 1 }
  local bounds = { x = 20, y = 80, width = 700, height = 600 }
  local clip = { x = 40, y = 100, width = 500, height = 330 }
  local visual = uiTheme.materialize(uiTheme.global(presets.BASE, 0), lovr.graphics.getDefaultFont())
  drawing.graph(pass, state, bounds, { theme = presets.BASE, visual = visual }, clip)
  local faces = {}
  for _, command in fake.events.draw do
    expect.truthy(command[1] ~= 'setScissor', 'the inset clip stays in logical coordinates')
    if command[1] == 'line' then
      for _, index in { 2, 5 } do
        expect.truthy(command[index] >= clip.x and command[index] <= clip.x + clip.width, 'inset line x')
        expect.truthy(command[index + 1] >= clip.y and command[index + 1] <= clip.y + clip.height, 'inset line y')
      end
    elseif command[1] == 'plane' then
      faces[#faces + 1] = command
      expect.truthy(command[2] - command[5] / 2 >= clip.x, 'inset face left')
      expect.truthy(command[2] + command[5] / 2 <= clip.x + clip.width, 'inset face right')
      expect.truthy(command[3] - command[6] / 2 >= clip.y, 'inset face top')
      expect.truthy(command[3] + command[6] / 2 <= clip.y + clip.height, 'inset face bottom')
    end
  end
  expect.equal(#faces, 2, 'both nodes remain visible in the inset clip')
  expect.near(faces[1][2], 210, 0.00001, 'the source keeps the declared graph x origin')
  expect.near(faces[1][3], 230, 0.00001, 'the source keeps the declared graph y origin')
  expect.near(faces[2][2], 480, 0.00001, 'the target face is clipped without translating it')
  expect.near(faces[2][5], 120, 0.00001, 'the target face stops at the inset clip')
end)

test('honours visibility filters and highlights selected nodes and edges', function()
  local fake, pass = fixture()
  local state = stateFor(snapshot())
  state.query = 'source'
  state.selection = { kind = 'node', id = 'source' }
  draw.render(pass, state, options())
  expect.truthy(hasText(fake.events, 'Source'))
  expect.falsy(hasText(fake.events, 'Target'))
  expect.falsy(hasText(fake.events, 'service'), 'edge to filtered target is omitted')
  expect.truthy(hasText(fake.events, 'loop'), 'self-loop of visible node remains')
  local selected = 0
  for _, command in fake.events.draw do
    if
      command[1] == 'setColor'
      and command[2][1] == presets.BASE.colors.focus[1]
      and command[2][2] == presets.BASE.colors.focus[2]
      and command[2][3] == presets.BASE.colors.focus[3]
    then
      selected += 1
    end
  end
  expect.equal(selected, 1, 'node selection highlight')
  table.clear(fake.events.draw)
  state.selection = { kind = 'edge', id = 'loop' }
  draw.render(pass, state, options())
  selected = 0
  for _, command in fake.events.draw do
    if
      command[1] == 'setColor'
      and command[2][1] == presets.BASE.colors.focus[1]
      and command[2][2] == presets.BASE.colors.focus[2]
      and command[2][3] == presets.BASE.colors.focus[3]
    then
      selected += 1
    end
  end
  expect.equal(selected, 1, 'edge selection highlight')
end)

test('shows empty graph, unmatched filters, off-canvas nodes, and empty sidebar states explicitly', function()
  local fake, pass = fixture()
  local state = view.new { x = 700, y = 600 }
  draw.render(pass, state, options())
  expect.truthy(hasText(fake.events, 'No plugins'))
  expect.truthy(hasText(fake.events, 'Select a plugin'))
  table.clear(fake.events.draw)
  state = stateFor(snapshot())
  state.query = 'missing'
  draw.render(pass, state, options())
  expect.truthy(hasText(fake.events, 'No plugins match'))
  table.clear(fake.events.draw)
  state.query = ''
  state.camera = { x = 10000, y = 10000, zoom = 1 }
  draw.render(pass, state, options())
  expect.truthy(hasText(fake.events, '2 plugins outside'))
end)

test('wraps text, preserves Unicode, reports overflow, and draws supplied control rectangles', function()
  local fake, pass = fixture()
  local settings = options()
  settings.details = { 'Unicode: λ漢字', string.rep('A long detail ', 100) }
  settings.rows = {
    { x = 710, y = 160, width = 275, height = 42, label = 'Value', value = '', selected = true, editable = true },
    {
      x = 710,
      y = 240,
      width = 100,
      height = 32,
      label = 'Long',
      value = string.rep('value ', 80),
      selected = false,
      editable = false,
    },
    {
      x = 710,
      y = 900,
      width = 275,
      height = 42,
      label = 'Below',
      value = 'hidden',
      selected = false,
      editable = false,
    },
  }
  settings.buttons = {
    { x = 12, y = 520, width = 110, height = 36, label = 'Fit graph', enabled = true },
    { x = 1500, y = 20, width = 100, height = 30, label = 'Outside', enabled = false },
  }
  settings.footer = 'Enter to apply.'
  draw.render(pass, view.new { x = 700, y = 600 }, settings)
  expect.truthy(hasText(fake.events, 'λ漢字'), 'UTF-8 label is not byte-truncated')
  expect.truthy(hasText(fake.events, 'lines)'), 'overflow is explicit')
  expect.truthy(hasText(fake.events, '(empty)'), 'empty value is explicit')
  expect.truthy(hasText(fake.events, 'rows outside'), 'offscreen rows are counted')
  expect.truthy(hasText(fake.events, 'buttons outside'), 'offscreen buttons are counted')
  expect.truthy(hasText(fake.events, 'Fit graph'))
  local found = false
  for _, command in fake.events.draw do
    if command[1] == 'plane' and command[2] == 67 and command[3] == 538 then
      expect.equal(command[5], 110, 'button width matches hit region')
      expect.equal(command[6], 36, 'button height matches hit region')
      found = true
    end
  end
  expect.truthy(found)
end)

test('places inspection details below a toolbar and above configuration rows', function()
  local fake, pass = fixture()
  local settings = options()
  settings.detailsTop = 202
  settings.details = { 'Inspection details', string.rep('more detail ', 80) }
  settings.buttons = {
    { x = 710, y = 8, width = 275, height = 32, label = 'Toolbar', enabled = true },
    { x = 710, y = 152, width = 275, height = 32, label = 'Inspect', enabled = true },
  }
  settings.rows = {
    {
      x = 710,
      y = 270,
      width = 275,
      height = 42,
      label = 'Config',
      value = 'value',
      selected = false,
      editable = true,
    },
  }
  draw.render(pass, view.new { x = 700, y = 600 }, settings)
  local found = false
  for _, command in fake.events.draw do
    if command[1] == 'text' and command[2] == 'Inspection details' then
      expect.equal(command[4], 202, 'details start below the toolbar')
      found = true
    end
  end
  expect.truthy(found, 'details remain visible below earlier toolbar buttons')
  expect.truthy(hasText(fake.events, 'lines)'), 'details overflow is explicit')
  expect.truthy(hasText(fake.events, 'Config: value'))
end)

test('hits enabled button rectangles in reverse drawing order with half-open bounds', function()
  local buttons = {
    { x = 10, y = 20, width = 100, height = 40, label = 'First', enabled = true },
    { x = 20, y = 25, width = 30, height = 20, label = 'Disabled', enabled = false },
    { x = 30, y = 30, width = 20, height = 20, label = 'Last', enabled = true },
  }
  expect.equal(draw.hit(buttons, { x = 10, y = 20 }), 1, 'top-left inclusive')
  expect.equal(draw.hit(buttons, { x = 25, y = 26 }), 1, 'disabled button is ignored')
  expect.equal(draw.hit(buttons, { x = 35, y = 35 }), 3, 'last drawn is topmost')
  expect.equal(draw.hit(buttons, { x = 50, y = 50 }), 1, 'last bottom-right excluded')
  expect.equal(draw.hit(buttons, { x = 110, y = 60 }), nil, 'outer bottom-right excluded')
  expect.equal(draw.hit({}, { x = 10, y = 20 }), nil)
end)

test('rejects invalid dimensions and content without a sidebar before drawing', function()
  local _, pass = fixture()
  for _, width in { 0, -1, math.huge, 0 / 0 } do
    local settings = options()
    settings.width = width
    expect.raises(function()
      draw.render(pass, view.new { x = 700, y = 600 }, settings)
    end, 'width')
    expect.equal(pass.stack.state, 0)
  end
  local settings = options()
  settings.sidebar = 0
  settings.details = { 'content' }
  expect.raises(function()
    draw.render(pass, view.new { x = 700, y = 600 }, settings)
  end, 'sidebar content')
  expect.equal(pass.stack.state, 0, 'validation precedes pass state changes')
end)

for _, failure in { 'text', 'getHeight', 'getLineSpacing', 'getWidth', 'getLines', 'pushState', 'pushTransform' } do
  test('restores caller stacks and settings after ' .. failure .. ' raises', function()
    local _, pass, font = fixture()
    pass:push 'state'
    pass:push 'transform'
    pass:push 'transform'
    pass.state = {
      setShader = { 'caller shader' },
      setMaterial = { 'caller material' },
      setFont = { 'caller font' },
      setCullMode = { 'back' },
      setDepthTest = { 'greater' },
      setDepthWrite = { true },
      setColor = { 0.2, 0.3, 0.4, 0.5 },
    }
    pass.transform = { x = 17, y = 23, scale = 2 }
    local originalState, originalTransform = table.clone(pass.state), table.clone(pass.transform)
    local target = if failure == 'text' or failure:sub(1, 4) == 'push' then pass else font
    local method = if failure:sub(1, 4) == 'push' then 'push' else failure
    local original = target[method]
    local raised = { operation = failure }
    target[method] = function(self, ...)
      local kind = ...
      if method ~= 'push' or kind == (if failure == 'pushState' then 'state' else 'transform') then
        error(raised, 0)
      end
      return original(self, ...)
    end
    local ok, message = pcall(draw.render, pass, view.new { x = 700, y = 600 }, options())
    expect.equal(ok, false, failure .. ' propagates')
    expect.equal(message, raised, 'original error is rethrown')
    target[method] = original
    local function nextDraw()
      expect.equal(pass.stack.state, 1, 'caller state stack is preserved')
      expect.equal(pass.stack.transform, 2, 'caller transform stack is preserved')
      expect.equal(#pass.saved.state, 1)
      expect.equal(#pass.saved.transform, 2)
      for setting, value in originalState do
        expect.equal(pass.state[setting], value, setting .. ' is restored')
      end
      for component, value in originalTransform do
        expect.equal(pass.transform[component], value, 'caller transform is restored')
      end
      pass:line(0, 0, 0, 1, 1, 0)
    end
    nextDraw()
    draw.render(pass, view.new { x = 700, y = 600 }, options())
    nextDraw()
  end)
end

test('rejects inspection details without an inner sidebar area before drawing', function()
  for _, dimensions in { { sidebar = 20 }, { sidebar = 24 }, { height = 20 }, { detailsTop = 544 } } do
    local fake, pass = fixture()
    local settings = options()
    for dimension, value in dimensions do
      settings[dimension] = value
    end
    settings.details = { 'Broker inspection unavailable' }
    expect.raises(function()
      draw.render(pass, view.new { x = 700, y = 600 }, settings)
    end, 'manager drawing:.*details.*sidebar')
    expect.equal(#fake.events.draw, 0, 'no pass operation precedes validation')
    expect.equal(pass.stack.state, 0)
    expect.equal(pass.stack.transform, 0)
  end
end)

test('attempts both pops and preserves a drawing error when cleanup also raises', function()
  local fake, pass = fixture()
  local drawError, restoreError = {}, {}
  pass.text = function()
    error(drawError, 0)
  end
  local pop = pass.pop
  pass.pop = function(self, kind)
    pop(self, kind)
    if kind == 'transform' then
      error(restoreError, 0)
    end
  end
  local ok, message = pcall(draw.render, pass, view.new { x = 700, y = 600 }, options())
  expect.equal(ok, false)
  expect.equal(message, drawError, 'cleanup does not replace the original error')
  expect.equal(pass.stack.state, 0, 'state pop follows a transform pop error')
  expect.equal(pass.stack.transform, 0)
  expect.equal(fake.events.draw[#fake.events.draw][2], 'state', 'cleanup order')
end)

test('renders through the frame callbacks with a caller-owned pass and no native acquisitions', function()
  local fake, pass = fixture()
  local state = stateFor(snapshot())
  local definition = plugin.define {
    name = 'manager-draw-test',
    requires = { frame = frameContract.capability },
    init = function(context)
      local frames = context:require(frameContract.capability)
      frames:onDraw(context, {
        phase = 'overlay',
        run = function(current)
          draw.render(current, state, options())
        end,
      })
    end,
  }
  local session = testing.boot({ 'frame', { id = 'manager-draw-test', definition = definition } }, { native = fake })
  local claims, outputs, writes = #fake.events.claims, #fake.events.outputs, fake.events.writes
  session:draw()
  expect.truthy(hasText(fake.events, 'Source'), 'frame draw renders graph')
  expect.equal(pass.stack.state, 0)
  expect.equal(pass.stack.transform, 0)
  expect.equal(#fake.events.claims, claims, 'render does not acquire layers')
  expect.equal(#fake.events.outputs, outputs, 'render does not acquire outputs')
  expect.equal(fake.events.writes, writes, 'render does not persist data')
  session:close()
end)

return test
