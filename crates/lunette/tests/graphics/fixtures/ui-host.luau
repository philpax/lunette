-- Renders host panels through the toolkit shader and checks faces, sides, depth order, and text.

local testing = require '@testing'
local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local ui = require './support/ui'
local test = testing.suite()

local element = uiHost.element

local function kinds(service: uiHost.Service, owner: any): ()
  service:registerKind(owner, {
    name = 'test/panel',
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props): lunette.LayoutStyle
        return { flexDirection = 'column', padding = 0.01, gap = 0.006, grow = 1 }
      end,
    },
    visuals = { 'test/panel' },
  })
  service:registerVisual(owner, 'test/panel', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    draw:box(nil, {
      fill = theme.colors.surface,
      radius = theme.radii.panel,
      side = theme.colors.side,
      depth = theme.elevation.panelDepth,
      edges = true,
    })
  end)
  service:registerKind(owner, {
    name = 'test/key',
    layout = {
      kind = 'container',
      style = function(): lunette.LayoutStyle
        return { padding = 0.006, alignSelf = 'start' }
      end,
    },
    elevation = 'raised',
    visuals = { 'test/key' },
  })
  service:registerVisual(owner, 'test/key', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    draw:box(nil, { fill = theme.colors.accent, radius = theme.radii.control, side = theme.colors.side, edges = true })
  end)
  service:registerKind(owner, {
    name = 'test/text',
    layout = {
      kind = 'text',
      text = function(props: uiHost.Props): string
        return props.text
      end,
      textStyle = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutTextStyle
        local style = theme.type.title
        return { family = style.family, size = style.size, weight = style.weight, lineHeight = style.lineHeight }
      end,
    },
    visuals = { 'test/text' },
  })
  service:registerVisual(owner, 'test/text', function(node: uiHost.Node, draw: uiHost.Draw)
    draw:text { color = node.props.color or node.theme.colors.ink }
  end)
end

local function channels(image: Image, x: number, y: number): (number, number, number)
  local r, g, b = image:getPixel(x, y)
  return r, g, b
end

local function close(image: Image, x: number, y: number, expected: { number }, label: string): ()
  local r, g, b = channels(image, x, y)
  for index, value in { r, g, b } do
    testing.expect.near(value, expected[index], 6 / 255, `{label} channel {index}`)
  end
end

test('a panel face, a raised key, and its label render in front of each other', function()
  local scene = ui.boot({}, {}, function(context: any)
    local service = context:require(uiHost.capability)
    kinds(service, context)
    local panel = service:newPanel(context, { name = 'basics', width = 0.2, height = 0.12, pose = lovr.math.newMat4() })
    local theme = service:theme()
    panel.root:bind {
      render = function()
        panel.root:submit(element('test/panel', {
          element('test/text', { key = 'title', text = 'Lunette' }),
          element('test/key', { key = 'key', element('test/text', { text = 'Run', color = theme.colors.accentInk }) }),
        }))
      end,
    }
  end)
  local image = ui.render(scene, 320, 200, vector.pack(0, 0, 0.32), vector.pack(0, 0, 0))
  ui.snapshot('host-front', image)
  local theme = scene.service:theme()
  -- The panel's bottom-right region is plain surface.
  close(image, 200, 130, theme.colors.surface, 'the panel face')
  local angled = ui.render(scene, 320, 200, vector.pack(0.18, -0.06, 0.24), vector.pack(0, 0, 0))
  ui.snapshot('host-angled', angled)
  scene.fixture:close()
end)

test('an SVG image is rasterised and drawn over its node', function()
  local svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" fill="#ff0000"/></svg>'
  local scene = ui.boot({}, {}, function(context: any)
    local service = context:require(uiHost.capability)
    kinds(service, context)
    service:registerKind(context, {
      name = 'test/picture',
      layout = {
        kind = 'leaf',
        style = function(): lunette.LayoutStyle
          return { width = 0.06, height = 0.06 }
        end,
      },
      visuals = { 'test/picture' },
    })
    service:registerVisual(context, 'test/picture', function(_node: uiHost.Node, draw: uiHost.Draw)
      draw:image(nil, { source = { kind = 'svg', data = svg } })
    end)
    local panel =
      service:newPanel(context, { name = 'pictures', width = 0.2, height = 0.12, pose = lovr.math.newMat4() })
    panel.root:bind {
      render = function()
        panel.root:submit(element('test/panel', { element('test/picture', { key = 'picture' }) }))
      end,
    }
  end)
  local image = ui.render(scene, 320, 200, vector.pack(0, 0, 0.32), vector.pack(0, 0, 0))
  ui.snapshot('host-image', image)
  -- The picture sits in the panel's padding at the top left; its centre is solid red.
  local found = false
  for x = 60, 160, 4 do
    for y = 30, 120, 4 do
      local r, g, b = image:getPixel(x, y)
      if r > 0.9 and g < 0.1 and b < 0.1 then
        found = true
      end
    end
  end
  testing.expect.truthy(found, 'red pixels from the rasterised SVG')
  scene.fixture:close()
end)

return test
