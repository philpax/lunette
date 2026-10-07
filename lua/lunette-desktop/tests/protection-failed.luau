-- A failed mandatory provider remains protected so management cannot remove the recovery path.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local keyboard = require '@lunette-contracts/keyboard'
local display = require '@lunette-contracts/keyboard-display'
local focus = require '@lunette-contracts/focus'
local surfaces = require '@lunette-contracts/surfaces'
local frame = require '@lunette-contracts/frame'
local fixture = require './support/protection'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local vrUi = require '@testing/vr-ui'
local lunette = require '@lunette'
local test = testing.suite()

test(
  'failed keyboard display bindings retain protection while unrelated inspection providers remain mutable',
  function()
    local failed = plugin.define {
      name = 'failed-keyboard-display',
      requires = {
        keyboard = keyboard.capability,
        focus = focus.capability,
        surfaces = surfaces.capability,
        frame = frame.capability,
      },
      provides = { display = display.capability },
      init = function()
        error('fixture keyboard acquisition failure', 0)
      end,
    }
    local services = {}
    local observer = plugin.define {
      name = 'failed-display-recovery-observer',
      requires = { ui = ui.capability, menu = menu.capability },
      init = function(context)
        services.ui = context:require(ui.capability)
        services.menu = context:require(menu.capability)
      end,
    }
    local service, native = fixture.boot {
      { id = 'desktop/keyboard', definition = failed },
      { insert = { id = 'failed-display-recovery-observer', definition = observer } },
    }
    local reports = testing.takeReports()
    expect.equal(#reports, 1, 'the failed provider is reported once')
    expect.truthy(reports[1]:find('fixture keyboard acquisition failure', 1, true), reports[1])
    expect.equal(
      fixture.entries(service)['desktop/keyboard'].state,
      'failed',
      'the failed provider remains inspectable'
    )
    fixture.assertProtected(service)
    expect.equal(
      fixture.entries(service)['desktop/menu'].state,
      'active',
      'the wrist menu survives keyboard acquisition failure'
    )
    expect.equal(fixture.entries(service)['desktop/actions'].state, 'active', 'the reload consumer survives')
    local foundReload = false
    for _, action in services.menu:list() do
      expect.truthy(action.id ~= 'desktop/keyboard/toggle', 'the unavailable Keyboard action is absent')
      foundReload = foundReload or action.id == 'desktop/reload'
    end
    expect.truthy(foundReload, 'Reload remains registered despite the failed display')
    local reload, calls = lunette.reload, 0
    lunette.reload = function()
      calls += 1
      return true
    end
    local ok, message = pcall(function()
      local controls = vrUi.attach(native)
      controls:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
      controls:tracked('left', true)
      controls:step()
      controls:clickControl(services.ui, 'desktop/menu', 'open')
      controls:clickControl(services.ui, 'desktop/menu', 'actions', 'right', 'desktop/reload')
      expect.equal(calls, 1, 'controller input reaches the public recovery action once')
    end)
    lunette.reload = reload
    if not ok then
      error(message, 0)
    end
    expect.falsy(fixture.entries(service).tags.protected, 'an inspection-only tags provider is not protected')
    service:disable 'tags'
    expect.equal(
      fixture.entries(service)['desktop/manager'].state,
      'active',
      'inspection can suspend during input failure'
    )
    fixture.finish(native)
  end
)

return test
