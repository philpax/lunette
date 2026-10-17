-- Renders host panels through the toolkit shader and checks faces, sides, depth order, and text.

local testing = require '@testing'
local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local ui = require './support/ui'
local renderer = require '@lunette-plugins/ui/host/private/rendering/renderer'
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
        return {
          family = style.family,
          size = props.size or style.size,
          weight = style.weight,
          lineHeight = style.lineHeight,
        }
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

test('text draws in the colour it was given, as a box does', function()
  -- A colour well below mid-grey shows whether the glyph shader converts it as the box shader does: drawn as linear,
  -- it comes out far lighter.
  local ink = { 0.2, 0.3, 0.45, 1 }
  local scene = ui.boot({}, {}, function(context: any)
    local service = context:require(uiHost.capability)
    kinds(service, context)
    local panel = service:newPanel(context, { name = 'ink', width = 0.2, height = 0.12, pose = lovr.math.newMat4() })
    panel.root:bind {
      render = function()
        panel.root:submit(element('test/panel', {
          element('test/text', { key = 'stem', text = 'I', size = 0.08, color = ink }),
        }))
      end,
    }
  end)
  local image = ui.render(scene, 320, 200, vector.pack(0, 0, 0.32), vector.pack(0, 0, 0))
  local surface = scene.service:theme().colors.surface
  -- The pixel that differs most from the panel face lies inside the stem.
  local farthest, found = -1, { 0, 0, 0 }
  for y = 0, 199 do
    for x = 0, 319 do
      local r, g, b = channels(image, x, y)
      local distance = math.abs(r - surface[1]) + math.abs(g - surface[2]) + math.abs(b - surface[3])
      if distance > farthest then
        farthest, found = distance, { r, g, b }
      end
    end
  end
  for index = 1, 3 do
    testing.expect.near(found[index], ink[index], 8 / 255, `the stem's channel {index}`)
  end
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
        kind = 'container',
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

test("a volume's own geometry rises out of the panel and the pass state returns afterwards", function()
  local scene = ui.boot({}, {}, function(context: any)
    local service = context:require(uiHost.capability)
    kinds(service, context)
    service:registerKind(context, {
      name = 'test/volume',
      layout = {
        kind = 'container',
        style = function(): lunette.LayoutStyle
          return { width = 0.06, height = 0.06 }
        end,
      },
      visuals = { 'test/volume' },
    })
    service:registerVisual(context, 'test/volume', function(_node: uiHost.Node, draw: uiHost.Draw)
      draw:volume(nil, {
        depth = 0.04,
        draw = function(pass: Pass, volume: uiHost.Volume): ()
          -- A shader of the volume's own, which the host must not leave set for the text drawn after it.
          pass:setShader 'unlit'
          pass:setColor(0, 1, 0, 1)
          pass:box(0, 0, volume.depth / 2, volume.width * 0.8, volume.height * 0.8, volume.depth)
        end,
      })
    end)
    local panel =
      service:newPanel(context, { name = 'volumes', width = 0.2, height = 0.12, pose = lovr.math.newMat4() })
    panel.root:bind {
      render = function()
        panel.root:submit(element('test/panel', {
          element('test/volume', { key = 'volume' }),
          element('test/text', { key = 'title', text = 'Lunette' }),
        }))
      end,
    }
  end)
  local function green(image: Image): number
    local count = 0
    for y = 0, 199, 2 do
      for x = 0, 319, 2 do
        local r, g, b = image:getPixel(x, y)
        if g > 0.9 and r < 0.1 and b < 0.1 then
          count += 1
        end
      end
    end
    return count
  end
  local front = ui.render(scene, 320, 200, vector.pack(0, 0, 0.32), vector.pack(0, 0, 0))
  ui.snapshot('host-volume', front)
  local seen = green(front)
  testing.expect.truthy(seen > 20, `the volume draws its box: {seen} samples`)
  -- From the side, a box that rises out of the panel covers more of the view than its face alone.
  local side = ui.render(scene, 320, 200, vector.pack(0.25, 0, 0.12), vector.pack(-0.06, 0.02, 0.02))
  ui.snapshot('host-volume-side', side)
  testing.expect.truthy(green(side) > 0, 'the box is visible from the side')
  -- The text after the volume still draws with the toolkit's glyph shader, in its theme ink.
  local ink = scene.service:theme().colors.ink
  local inked = false
  for y = 0, 199 do
    for x = 0, 319 do
      local r, g, b = front:getPixel(x, y)
      if math.abs(r - ink[1]) < 0.03 and math.abs(g - ink[2]) < 0.03 and math.abs(b - ink[3]) < 0.03 then
        inked = true
      end
    end
  end
  testing.expect.truthy(inked, 'the title draws in its ink after the volume')
  scene.fixture:close()
end)

test('images retain panel placement, UV, tint, and clipping through poses and enclosing transforms', function()
  local scene = ui.boot({}, {}, function() end)
  local resources, release = renderer.acquire(function(message: string)
    error(message, 0)
  end)
  local source = lovr.data.newImage(2, 2, 'rgba8')
  source:setPixel(0, 0, 1, 0, 0, 1)
  source:setPixel(1, 0, 0, 1, 0, 1)
  source:setPixel(0, 1, 0, 0, 1, 1)
  source:setPixel(1, 1, 1, 1, 1, 1)
  local texture = lovr.graphics.newTexture(source, { mipmaps = false })
  local tint = { 0.4, 0.65, 0.8, 0.75 }
  local rect = { x = 0.025, y = 0.02, width = 0.12, height = 0.075, z = 0.008 }
  local clip = { 0.045, 0.03, 0.13, 0.085 }
  local oracleShader = lovr.graphics.newShader(
    [[
    out vec2 imageUV;
    vec4 lovrmain() {
      imageUV = VertexUV;
      return DefaultPosition;
    }
  ]],
    [[
    uniform vec4 imageClip;
    uniform vec4 imageRect;
    in vec2 imageUV;
    vec4 lovrmain() {
      vec2 panel = imageRect.xy + imageUV * imageRect.zw;
      if (panel.x < imageClip.x || panel.y < imageClip.y || panel.x > imageClip.z || panel.y > imageClip.w) {
        discard;
      }
      vec4 color = Color * getPixel(ColorTexture, imageUV);
      color.rgb *= .55;
      return color;
    }
  ]]
  )
  local function render(panel: any, enclosing: Mat4, oracle: boolean): Image
    local target = lovr.graphics.newTexture(160, 120, {
      format = 'rgba8',
      linear = false,
      mipmaps = false,
      usage = { 'render', 'transfer' },
    })
    local depth = lovr.graphics.newTexture(160, 120, { format = 'd32f', usage = 'render' })
    local pass = lovr.graphics.newPass { texture = target, depth = depth, samples = 1 }
    pass:setClear(0.02, 0.02, 0.03, 1)
    pass:setViewPose(1, lovr.math.mat4():target(vector.pack(0, 0, 0.4), vector.zero, vector.pack(0, 1, 0)))
    pass:setProjection(1, lovr.math.mat4():perspective(math.rad(40), 4 / 3, 0.01, 0))
    pass:transform(enclosing)
    pass:setShader 'unlit'
    pass:setColor(0.8, 0.2, 0.1, 1)
    pass:setMaterial(nil)
    pass:setCullMode 'none'
    pass:setBlendMode('alpha', 'alphamultiply')
    pass:setDepthWrite(true)
    local mesh: Mesh? = nil
    if oracle then
      local vertices = {}
      for _, corner in { { 0, 1 }, { 1, 1 }, { 0, 0 }, { 1, 0 } } do
        local u, v = corner[1], corner[2]
        local x = rect.x + u * rect.width - panel.width / 2
        local y = panel.height / 2 - rect.y - v * rect.height
        local z = rect.z
        if panel.curve > 0 then
          local radius = 1 / panel.curve
          local angle = x * panel.curve
          x, z = (radius - z) * math.sin(angle), radius - (radius - z) * math.cos(angle)
        end
        local wx, wy, wz = panel.pose:mul(x, y, z)
        table.insert(vertices, { wx, wy, wz, 0, 0, 1, u, v })
      end
      mesh = lovr.graphics.newMesh(vertices)
      mesh:setIndices { 1, 2, 3, 3, 2, 4 }
      pass:push 'state'
      pass:setShader(oracleShader)
      pass:send('imageClip', clip)
      pass:send('imageRect', { rect.x, rect.y, rect.width, rect.height })
      pass:setCullMode 'none'
      pass:setBlendMode('alpha', 'alphamultiply')
      pass:setDepthWrite(false)
      pass:setMaterial(texture)
      pass:setColor(tint[1], tint[2], tint[3], tint[4])
      pass:draw(mesh)
      pass:pop 'state'
    else
      renderer.draw(
        resources,
        pass,
        panel,
        {
          count = 0,
          volumes = {},
          glyphCounts = {},
          images = {
            {
              x = rect.x,
              y = rect.y,
              width = rect.width,
              height = rect.height,
              z = rect.z,
              clip = clip,
              tint = tint,
              source = { kind = 'texture', texture = texture },
            },
          },
        } :: any,
        scene.service:theme(),
        true,
        function(_label: string, draw: () -> ()): boolean
          draw()
          return true
        end
      )
    end
    -- The image does not write depth, and its shader, material, colour, and depth state do not reach later draws.
    pass:plane(-0.015, -0.015, -0.02, 0.02, 0.02)
    pass:setColor(0, 0.8, 0, 1)
    pass:plane(-0.015, -0.015, -0.04, 0.03, 0.03)
    lovr.graphics.submit(pass)
    local readback = target:newReadback()
    lovr.graphics.submit {}
    readback:wait()
    local image = assert(readback:getImage())
    if mesh then
      mesh:release()
    end
    pass:release()
    depth:release()
    target:release()
    return image
  end
  local posed = lovr.math.newMat4():translate(0.025, -0.01, -0.015):rotate(0.25, 0, 1, 0):rotate(0.1, 0, 0, 1)
  for _, case in
    {
      { name = 'flat', curve = 0, pose = lovr.math.newMat4(), enclosing = lovr.math.newMat4() },
      { name = 'posed', curve = 0, pose = posed, enclosing = lovr.math.newMat4() },
      { name = 'curved', curve = 3, pose = posed, enclosing = lovr.math.newMat4() },
      {
        name = 'enclosed',
        curve = 3,
        pose = posed,
        enclosing = lovr.math.newMat4():translate(-0.02, 0.015, -0.01):rotate(-0.2, 0, 1, 0):scale(0.9),
      },
    }
  do
    local panel = { width = 0.2, height = 0.12, curve = case.curve, pose = case.pose }
    local actual = render(panel, case.enclosing, false)
    local expected = render(panel, case.enclosing, true)
    local different = 0
    local colored = 0
    for y = 0, 119 do
      for x = 0, 159 do
        local ar, ag, ab = actual:getPixel(x, y)
        local er, eg, eb = expected:getPixel(x, y)
        if math.max(math.abs(ar - er), math.abs(ag - eg), math.abs(ab - eb)) > 4 / 255 then
          different += 1
        end
        if math.max(er, eg, eb) > 0.15 then
          colored += 1
        end
      end
    end
    testing.expect.truthy(colored > 200, `{case.name} oracle draws the image: {colored} pixels`)
    testing.expect.truthy(
      different < 12,
      `{case.name} image differs from its panel-coordinate oracle at {different} pixels`
    )
  end
  oracleShader:release()
  texture:release()
  source:release()
  release()
  scene.fixture:close()
end)

return test
