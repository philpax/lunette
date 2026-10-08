-- The shipped session action consumers use the wrist menu instead of physical reload or workspace bindings.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local vrUi = require '@testing/vr-ui'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local display = require '@lunette-contracts/keyboard-display'
local keyboard = require '@lunette-contracts/keyboard'
local bindings = require '@lunette-contracts/bindings'
local tags = require '@lunette-contracts/tags'
local surfaces = require '@lunette-contracts/surfaces'
local lunette = require '@lunette'
local test = testing.suite()

test('wrist menu actions are VR accessible and session actions do not register physical bindings', function()
  local native = testing.native()
  local services = {}
  local observer = plugin.define {
    name = 'session-action-observer',
    requires = {
      ui = ui.capability,
      menu = menu.capability,
      display = display.capability,
      keyboard = keyboard.capability,
      bindings = bindings.capability,
      tags = tags.capability,
      surfaces = surfaces.capability,
    },
    init = function(context)
      services.ui = context:require(ui.capability)
      services.menu = context:require(menu.capability)
      services.display = context:require(display.capability)
      services.keyboard = context:require(keyboard.capability)
      services.bindings = context:require(bindings.capability)
      services.tags = context:require(tags.capability)
      services.surfaces = context:require(surfaces.capability)
    end,
  }
  desktop.run {
    workspaces = { workspaces = { { name = 'main' }, { name = 'side' } } },
    patches = {
      { id = 'laser', config = { aim = { enabled = false } } },
      { insert = { id = 'session-action-observer', definition = observer } },
    },
  }
  lovr.load()
  local reloads = 0
  lunette.reload = function()
    reloads += 1
    return true
  end
  expect.equal(services.bindings:inspect().logicalRegistrationCount, 0, 'no shipped session chord is registered')
  for _, key in { 'f5', '1', '2' } do
    lovr.keypressed(key, 0, false)
    native.events.held.lalt = true
    lovr.keypressed(key, 0, false)
    native.events.held = {}
  end
  expect.equal(reloads, 0, 'physical keys do not reload the configuration')
  expect.truthy(services.tags:find('main').selected, 'physical keys do not change the workspace')

  local fixture = vrUi.attach(native)
  fixture:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
  fixture:tracked('left', true)
  fixture:step()
  fixture:clickControl(services.ui, 'desktop/menu', 'open')
  local function invoke(id)
    fixture:clickControl(services.ui, 'desktop/menu', 'actions', 'right', id)
  end
  invoke 'desktop/keyboard/toggle'
  expect.truthy(services.display:isVisible(), 'Keyboard shows the shared board')
  local function countBoards()
    local count = 0
    for _, registration in services.keyboard:inspect().registrations do
      if registration.kind == 'keyboard' and registration.live then
        count += 1
      end
    end
    return count
  end
  expect.equal(countBoards(), 1, 'the desktop acquires one actual keyboard')
  invoke 'desktop/keyboard/toggle'
  expect.falsy(services.display:isVisible(), 'Keyboard hides the shared board')
  invoke 'desktop/keyboard/toggle'
  expect.equal(countBoards(), 1, 'showing reuses that keyboard')
  invoke 'desktop/keyboard/toggle'
  invoke 'desktop/workspace/side'
  expect.truthy(services.tags:find('side').selected, 'a pointer chooses the side workspace')
  invoke 'desktop/workspace/main'
  expect.truthy(services.tags:find('main').selected, 'a pointer returns to main')
  invoke 'desktop/reload'
  expect.equal(reloads, 1, 'a pointer invokes public reload once')
  local beforeManager = #services.surfaces:all()
  invoke 'desktop/manager/open'
  expect.equal(#services.surfaces:all(), beforeManager + 1, 'Plugins opens the manager surface')
  fixture:clickControl(services.ui, 'desktop/menu', 'close')
  fixture:discover(services.ui, 'desktop/menu', 'open')
  expect.equal(#testing.host.shutdown(), 0, 'the session releases its resources')
  native.assertResourcesReleased()
end)

return test
