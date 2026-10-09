local testing = require '@testing'
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local controller = require '../controller'
local drawing = require '../draw'
local base = require '@lunette-plugins/theme/base'
local uiTheme = require '@lunette-plugins/ui/theme'

-- Draws the graph and each sidebar part the way the manager's regions do.
local function render(pass, state, settings)
  local visual = uiTheme.materialize(uiTheme.global(base, 0), lovr.graphics.getDefaultFont())
  local style = { theme = base, visual = visual }
  drawing.graph(pass, state, {
    x = 0,
    y = 0,
    width = math.min(state.viewport.x, settings.width - settings.sidebar),
    height = math.min(state.viewport.y, settings.height),
  }, style)
  local boxes = drawing.sidebarGeometry(settings)
  for _, part in { 'background', 'details', 'footer' } do
    drawing.details(pass, settings, boxes[part], part, style)
  end
end
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
  return {
    width = 1000,
    height = 600,
    sidebar = 300,
    details = {},
    wrappedDetails = false,
    detailsTop = 12,
    footer = '',
  }
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

test('scrolling reaches a long wrapped diagnostic tail', function()
  local fake, pass, font = fixture()
  local marker = 'DIAGNOSTIC_TAIL_MARKER'
  local message = string.rep('diagnostic words ', 240) .. '\n' .. marker
  local definition = plugin.define {
    name = 'manager-long-diagnostic',
    init = function()
      error(message, 0)
    end,
  }
  local running = management.start { { id = 'failure', definition = definition } }
  testing.takeReports()
  local selected = running.service:entries()[2]
  local state = controller.new(running.service, {}, 1000, 600)
  state.view.selection = { kind = 'node', id = selected.instanceId }
  controller.update(state)
  controller.measureDetails(state, font, base.typography.bodySize)
  render(pass, state.view, controller.options(state))
  expect.equal(hasText(fake.events, marker), false, 'the tail starts outside the visible body')
  local seen = false
  for _ = 1, 600 do
    controller.scrollBy(state, 1)
    table.clear(fake.events.draw)
    render(pass, state.view, controller.options(state))
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
  render(pass, state.view, controller.options(state))
  expect.equal(hasText(fake.events, last), true, 'the final record is rendered')
  controller.scrollBy(state, -1)
  expect.equal(state.scroll, math.max(0, lastIndex - 1), 'scrolling also returns from the end')
  running.runtime:close()
end)

test('clips all graph geometry in logical coordinates without a framebuffer scissor', function()
  local fake, pass = fixture()
  local state = stateFor(snapshot())
  state.camera = { x = 230, y = 170, zoom = 4 }
  state.viewport = { x = 420, y = 330 }
  drawing.graph(
    pass,
    state,
    { x = 0, y = 0, width = 420, height = 330 },
    { theme = base, visual = uiTheme.materialize(uiTheme.global(base, 0), lovr.graphics.getDefaultFont()) }
  )
  expect.truthy(#lines(fake.events) > 0, 'the edge arrows are drawn inside the clip')
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
  local visual = uiTheme.materialize(uiTheme.global(base, 0), lovr.graphics.getDefaultFont())
  drawing.graph(pass, state, bounds, { theme = base, visual = visual }, clip)
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

return test
