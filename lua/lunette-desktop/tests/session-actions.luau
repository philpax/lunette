-- Every shipped session action is reachable through the wrist menu.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local desktop = require '@lunette-desktop'
local vrUi = require '@testing/vr-ui'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local display = require '@lunette-contracts/keyboard-display'
local tags = require '@lunette-contracts/tags'
local surfaces = require '@lunette-contracts/surfaces'
local lunette = require '@lunette'
local theme = require '@lunette-contracts/theme'
local test = testing.suite()

test('wrist menu actions are VR accessible', function()
  local native = testing.native()
  local services = {}
  local observer = adapter.define {
    name = 'session-action-observer',
    requires = {
      ui.capability,
      menu.capability,
      display.capability,
      tags.capability,
      surfaces.capability,
      theme.capability,
    },
    init = function(context)
      services.ui = context:require(ui.capability)
      services.menu = context:require(menu.capability)
      services.display = context:require(display.capability)
      services.tags = context:require(tags.capability)
      services.surfaces = context:require(surfaces.capability)
      services.theme = context:require(theme.capability)
    end,
  }
  desktop.run {
    settings = { workspaces = { workspaces = { { name = 'main' }, { name = 'side' } } } },
    patches = {
      { id = 'laser', config = { aim = { enabled = false }, triggerLock = { enabled = false } } },
      { insert = { id = 'session-action-observer', definition = observer } },
    },
  }
  lovr.load()
  local reloads = 0
  lunette.reload = function()
    reloads += 1
    return true
  end
  local fixture = vrUi.attach(native)
  fixture:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
  fixture:tracked('left', true)
  fixture:step()
  fixture:clickControl(services.ui, 'desktop/menu', 'open')
  local function invoke(id)
    fixture:axis('right', 0, 0)
    fixture:button('right', 'trigger', false)
    local description, list = fixture:discover(services.ui, 'desktop/menu', 'actions')
    fixture:aim(description, list.bounds.x + list.bounds.width / 2, list.bounds.y + list.bounds.height / 2, 'right')
    fixture:step()
    for _ = 1, #services.menu:list() do
      fixture:axis('right', 0, 1)
      fixture:step(0.1)
    end
    for _ = 1, #services.menu:list() do
      local found, _, item = pcall(fixture.discover, fixture, services.ui, 'desktop/menu', 'actions', id)
      if found and item.bounds and item.bounds.height > 0 then
        break
      end
      fixture:axis('right', 0, -1)
      fixture:step(0.1)
    end
    fixture:axis('right', 0, 0)
    fixture:step()
    fixture:clickControl(services.ui, 'desktop/menu', 'actions', 'right', id)
  end
  invoke 'desktop/theme/arcade'
  expect.equal(services.theme:current().theme.typography.font.kind, 'file', 'Appearance selects Arcade')
  invoke 'desktop/keyboard/toggle'
  expect.truthy(services.display:isVisible(), 'Keyboard shows the shared board')
  invoke 'desktop/keyboard/toggle'
  expect.falsy(services.display:isVisible(), 'Keyboard hides the shared board')
  invoke 'desktop/workspace/side'
  expect.truthy(services.tags:find('side').selected, 'a pointer chooses the side workspace')
  invoke 'desktop/reload'
  expect.equal(reloads, 1, 'a pointer invokes public reload once')
  local beforeManager = #services.surfaces:all()
  invoke 'desktop/manager/open'
  expect.equal(#services.surfaces:all(), beforeManager + 3, 'Plugins opens the manager and titlebar surfaces')
  fixture:clickControl(services.ui, 'desktop/menu/titlebar', 'close')
  fixture:discover(services.ui, 'desktop/menu', 'open')
  local shutdown = testing.host.shutdown()
  expect.equal(#shutdown, 0, 'the session releases its resources: ' .. table.concat(shutdown, '\n'))
  native.assertResourcesReleased()
end)

return test
