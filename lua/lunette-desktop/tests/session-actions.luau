-- Every shipped session action is reachable through the wrist menu.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local desktop = require '@lunette-desktop'
local vrUi = require '@testing/vr-ui'
local uiPanels = require '@testing/ui-panels'
local wristMenu = require '@testing/wrist-menu'
local menu = require '@lunette-contracts/menu'
local display = require '@lunette-contracts/keyboard-display'
local tags = require '@lunette-contracts/tags'
local surfaces = require '@lunette-contracts/surfaces'
local lunette = require '@lunette'
local test = testing.suite()

test('wrist menu actions are VR accessible', function()
  local native = testing.native()
  local services: {
    menu: menu.Service?,
    display: display.Service?,
    tags: tags.Service?,
    surfaces: surfaces.Service?,
  } =
    {}
  local observer = adapter.define {
    name = 'session-action-observer',
    requires = {
      menu.capability,
      display.capability,
      tags.capability,
      surfaces.capability,
    },
    init = function(context: adapter.Context)
      services.menu = context:require(menu.capability)
      services.display = context:require(display.capability)
      services.tags = context:require(tags.capability)
      services.surfaces = context:require(surfaces.capability)
    end,
  }
  local panels = uiPanels.new()
  desktop.run {
    settings = { ['desktop/workspaces'] = { names = { 'main', 'side' } } },
    patches = {
      { id = 'laser', config = { aim = { enabled = false }, triggerLock = { enabled = false } } },
      { id = 'ui-host', definition = panels.definition },
      { insert = { id = 'session-action-observer', definition = observer } },
    },
  }
  lovr.load()
  local reloads = 0
  lunette.reload = function(): boolean
    reloads += 1
    return true
  end
  local fixture = vrUi.attach(native)
  fixture:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
  fixture:tracked('left', true)
  fixture:step()
  wristMenu.open(fixture, panels)
  local function invoke(id: string)
    panels:click(fixture, wristMenu.PANEL, wristMenu.row(id), 'right')
  end
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
  expect.equal(#services.surfaces:all(), beforeManager + 1, 'Plugins opens the manager panel surface')
  wristMenu.close(fixture, panels)
  expect.truthy(panels:node(wristMenu.PANEL, 'open'), 'Close returns the menu to its wrist button')
  local shutdown = testing.host.shutdown()
  expect.equal(#shutdown, 0, 'the session releases its resources: ' .. table.concat(shutdown, '\n'))
  native.assertResourcesReleased()
end)

return test
