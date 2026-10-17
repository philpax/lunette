-- Renders the backdrop control panel's views, which draw the backdrop's own shaders and meshes in UI volumes.

local testing = require '@testing'
local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local config = require '@lunette-plugins/environment/backdrop/config'
local model = require '@lunette-plugins/environment/backdrop/private/rendering/model'
local draw = require '@lunette-plugins/environment/backdrop/private/rendering/draw'
local kinds = require '@lunette-plugins/environment/backdrop/private/visualisation/kinds'
local scene = require '@lunette-plugins/environment/backdrop/private/visualisation/scene'
local ui = require './support/ui'
local test = testing.suite()

local element = uiHost.element

-- A loud, right-leaning frame with an onset in each band.
local function observed(): scene.Observed
  local settings = config.schema.parse {}
  local state = model.new(settings)
  local spectrum = { 0.9, 0.7, 0.5, 0.6, 0.8, 0.4, 0.3, 0.5 }
  local stereo = { 0.3, 0.2, 0, -0.2, 0.4, 0, 0.1, -0.3 }
  state:setFeatures({ bass = 0.8, mid = 0.6, treble = 0.4, spectrum = spectrum, stereo = stereo }, {
    { strength = 1, position = 0.45, band = 'bass' },
    { strength = 1, position = 0.55, band = 'mid' },
    { strength = 1, position = 0.6, band = 'treble' },
  })
  state:update(0.5, false)
  local frame = state:update(0.1, false)
  return { frame = frame, raw = table.clone(spectrum), facing = 0.5, anchor = 0.5 }
end

local function lit(image: Image, left: number, top: number, right: number, bottom: number): number
  local count = 0
  for y = top, bottom - 1, 2 do
    for x = left, right - 1, 2 do
      local r, g, b = image:getPixel(x, y)
      if r + g + b > 0.25 then
        count += 1
      end
    end
  end
  return count
end

test('the sky model and the skyline draw out of the panel in their own shaders', function()
  local sceneUnderTest = ui.boot({}, {}, function(context: any)
    local service = context:require(uiHost.capability)
    local settings = config.schema.parse {}
    local renderer = draw.new(context, settings, function(): any
      return 'none'
    end)
    local seen = observed()
    local history: { scene.Row } = {}
    for _ = 1, scene.ROWS do
      scene.push(history, scene.row(seen.frame))
    end
    local views = kinds.register(service, context, {
      observed = seen,
      history = history,
      palette = settings.palette,
      miniature = renderer.miniature,
      sectors = 12,
      hold = 0.65,
    })
    service:registerKind(context, {
      name = 'test/row',
      layout = {
        kind = 'container',
        style = function(): lunette.LayoutStyle
          return { flexDirection = 'row', gap = 0.01, padding = 0.01, grow = 1 }
        end,
      },
    })
    local panel = service:newPanel(context, { name = 'views', width = 0.42, height = 0.15, pose = lovr.math.newMat4() })
    panel.root:bind {
      render = function()
        panel.root:submit(element('test/row', {
          views.Model { key = 'model', size = 0.13 },
          views.Skyline { key = 'skyline', height = 0.13 },
        }))
      end,
    }
  end)
  local front = ui.render(sceneUnderTest, 480, 240, vector.pack(0, 0.08, 0.5), vector.pack(0, 0, 0))
  ui.snapshot('backdrop-views-front', front)
  local above = ui.render(sceneUnderTest, 480, 240, vector.pack(-0.05, 0.35, 0.35), vector.pack(-0.06, 0, 0.05))
  ui.snapshot('backdrop-views-above', above)
  local close = ui.render(sceneUnderTest, 480, 360, vector.pack(-0.135, 0.17, 0.2), vector.pack(-0.135, 0, 0.065))
  ui.snapshot('backdrop-views-model', close)
  testing.expect.truthy(lit(front, 60, 20, 200, 220) > 100, 'the sky model lights its side of the panel')
  testing.expect.truthy(lit(front, 220, 20, 460, 220) > 100, 'the skyline lights its side of the panel')
  sceneUnderTest.fixture:close()
end)

return test
