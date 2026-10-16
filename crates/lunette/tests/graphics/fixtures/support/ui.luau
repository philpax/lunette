-- Boots the UI host in a test session and renders its panels through real LÖVR graphics.
-- The session installs recording fakes for LÖVR's graphics; the real modules are put back once it has booted.

local host = require '@testing/host'
local vrUi = require '@testing/vr-ui'
local adapter = require '@lunette-plugin/adapter'
local uiHost = require '@lunette-contracts/ui-host'

local ui = {}

export type Scene = {
  fixture: vrUi.Fixture,
  service: uiHost.Service,
  owner: adapter.Context,
}

local FONTS = {
  { family = 'IBM Plex Sans', weight = 400, file = '@lunette-plugins/ui/standard/fonts/IBMPlexSans-Regular.ttf' },
  { family = 'IBM Plex Sans', weight = 500, file = '@lunette-plugins/ui/standard/fonts/IBMPlexSans-Medium.ttf' },
  { family = 'IBM Plex Sans', weight = 600, file = '@lunette-plugins/ui/standard/fonts/IBMPlexSans-SemiBold.ttf' },
  { family = 'Iosevka', weight = 400, file = '@lunette-plugins/ui/standard/fonts/Iosevka-Regular.ttf' },
}

-- Definitions are extra plugins, such as the standard kinds, used once the real graphics and file reading are back;
-- setup runs inside a consumer plugin.
function ui.boot(definitions: { any }, requires: { any }, setup: (adapter.Context) -> ()): Scene
  local graphics, data = lovr.graphics, lovr.data
  local fixture = vrUi.boot {
    'frame',
    'surfaces',
    'focus',
    { id = 'ui-host', definition = require('@lunette-plugins/ui/host').definition },
  }
  lovr.graphics, lovr.data = graphics, data
  lovr.filesystem = { read = host.readFile } :: any
  local session = assert(fixture.session)
  for _, definition in definitions do
    session:use(definition, {})
  end
  local scene: Scene = { fixture = fixture } :: any
  local needed = { uiHost.capability }
  for _, capability in requires do
    table.insert(needed, capability)
  end
  assert(fixture.session):use(
    adapter.define {
      name = 'testing/ui-graphics-consumer',
      requires = needed,
      init = function(context: adapter.Context)
        scene.owner = context
        scene.service = context:require(uiHost.capability)
        for _, font in FONTS do
          scene.service:registerFont(context, font)
        end
        setup(context)
      end,
    },
    {}
  )
  return scene
end

-- Renders the scene from a camera at `eye` looking at `target`, and returns the image.
function ui.render(scene: Scene, width: number, height: number, eye: vector, target: vector): Image
  scene.fixture:step()
  local texture = lovr.graphics.newTexture(width, height, {
    format = 'rgba8',
    linear = false,
    samples = 1,
    mipmaps = false,
    usage = { 'render', 'transfer' },
  })
  local depth = lovr.graphics.newTexture(width, height, { format = 'd32f', usage = 'render', samples = 1 })
  local pass = lovr.graphics.newPass { texture = texture, depth = depth, samples = 1 }
  pass:setClear(0.02, 0.02, 0.03, 1)
  local view = lovr.math.mat4():target(eye, target, vector.pack(0, 1, 0))
  pass:setViewPose(1, view)
  pass:setProjection(1, lovr.math.mat4():perspective(math.rad(40), width / height, 0.01, 0))
  lovr.draw(pass)
  lovr.graphics.submit(pass)
  local readback = texture:newReadback()
  lovr.graphics.submit {}
  readback:wait()
  local image = assert(readback:getImage(), 'the readback has no image')
  local reported = scene.fixture.native.events.reported
  if #reported > 0 then
    error('the host reported: ' .. reported[1].message .. '\n' .. reported[1].traceback, 0)
  end
  return image
end

function ui.snapshot(name: string, image: Image): ()
  host.writeSnapshot(name, image:encode():getString())
end

return ui
