-- Desktop management protects the recovery path, including a failed keyboard, and not optional providers.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local composition = require '@lunette-contracts/composition'
local keyboard = require '@lunette-contracts/keyboard'
local display = require '@lunette-contracts/keyboard-display'
local focus = require '@lunette-contracts/focus'
local surfaces = require '@lunette-contracts/surfaces'
local frame = require '@lunette-contracts/frame'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local vrUi = require '@testing/vr-ui'
local lunette = require '@lunette'
local test = testing.suite()

local MANDATORY = {
  'composition',
  'frame',
  'surfaces',
  'focus',
  'interaction',
  'laser',
  'keyboard',
  'ui',
  'menu',
  'desktop/pointing',
  'desktop/keyboard',
  'desktop/menu',
  'desktop/actions',
  'desktop/manager',
}

local function entries(service)
  local result = {}
  for _, entry in service:entries() do
    result[entry.id] = entry
  end
  return result
end

test('a failed keyboard stays protected with Reload reachable, and an optional provider can be disabled', function()
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
    name = 'desktop-protection-observer',
    requires = { composition = composition.capability, ui = ui.capability, menu = menu.capability },
    init = function(context)
      services.composition = context:require(composition.capability)
      services.ui = context:require(ui.capability)
      services.menu = context:require(menu.capability)
    end,
  }
  local native = testing.native()
  desktop.run {
    patches = {
      { id = 'desktop/keyboard', definition = failed },
      { insert = { id = 'desktop-protection-observer', definition = observer } },
    },
  }
  lovr.load()
  local service = assert(services.composition)

  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the failed provider is reported once')
  expect.truthy(reports[1]:find('fixture keyboard acquisition failure', 1, true), reports[1])
  local current = entries(service)
  expect.equal(current['desktop/keyboard'].state, 'failed', 'the failed provider remains inspectable')
  for _, id in MANDATORY do
    expect.truthy(current[id].protected, id .. ' protects the VR recovery path')
  end
  expect.raises(function()
    service:disable 'desktop/keyboard'
  end, 'required for management or recovery', 'a protected failed keyboard')
  expect.equal(current['desktop/menu'].state, 'active', 'the wrist menu survives keyboard acquisition failure')
  expect.equal(current['desktop/actions'].state, 'active', 'the reload consumer survives')
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

  expect.falsy(current.pacing.protected, 'an optional provider is not protected')
  service:disable 'pacing'
  expect.truthy(entries(service).pacing.state ~= 'active', 'the optional provider can be suspended')
  expect.equal(entries(service)['desktop/manager'].state, 'active', 'optional suspension does not stop the manager')
  service:enable 'pacing'
  expect.equal(entries(service).pacing.state, 'active', 'the optional provider reconnects')

  expect.equal(#testing.host.shutdown(), 0, 'the desktop shuts down without failures')
  native.assertResourcesReleased()
end)

return test
