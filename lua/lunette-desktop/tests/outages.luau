-- A provider outage removes only what depends on it, and the VR recovery path stays reachable through it.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local lunette = require '@lunette'
local panelsContract = require '@lunette-contracts/panels'
local displayContract = require '@lunette-contracts/keyboard-display'
local menuContract = require '@lunette-contracts/menu'
local uiContract = require '@lunette-contracts/ui'
local vrUi = require '@testing/vr-ui'

local test = testing.suite()

test('keyboard and frame outages remove only what depends on them, and recovery restores it', function()
  local session = testing.boot(desktop.compose())
  local native, events, instances = session.native, session.native.events, session.instances
  local panels = session:observe(panelsContract.capability).service
  local display = session:observe(displayContract.capability)
  local menu = session:observe(menuContract.capability).service
  local ui = session:observe(uiContract.capability).service
  local function action(id: string): menuContract.Descriptor?
    for _, entry in menu:list() do
      if entry.id == id then
        return entry
      end
    end
    return nil
  end
  local window = native.newWindow(10)
  events.windows = { window }
  native.emit('onWindowOpened', { window = window })
  local panel = assert(panels:forSource(window))
  display.service:show()
  session:update()

  instances.keyboard:disable()
  expect.equal(panels:forSource(window), panel, 'the window panel stays')
  expect.equal(instances['desktop/menu']:state(), 'active', 'the wrist menu survives')
  expect.equal(action 'desktop/keyboard/toggle', nil, 'only the Keyboard action disappears')
  local reloads = 0
  local reload = lunette.reload
  lunette.reload = function(): boolean
    reloads += 1
    return true
  end
  local ok, failure = pcall(function()
    local controls = vrUi.attach(native)
    controls:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
    controls:tracked('left', true)
    controls:step()
    controls:clickControl(ui, 'desktop/menu', 'open')
    controls:clickControl(ui, 'desktop/menu', 'actions', 'right', 'desktop/reload')
  end)
  lunette.reload = reload
  if not ok then
    error(failure, 0)
  end
  expect.equal(reloads, 1, 'the controller reaches Reload during the outage')

  instances.keyboard:enable()
  expect.truthy(action 'desktop/keyboard/toggle', 'the Keyboard action returns')
  expect.truthy(display.service:show(), 'the keyboard shows again after recovery')

  instances.frame:disable()
  expect.truthy(instances['desktop/render']:state() ~= 'active', 'a frame outage stops rendering')
  expect.truthy(panels:forSource(window) == panel and not panel.dead, 'a frame outage keeps the panel')
  instances.frame:enable()
  expect.equal(instances['desktop/render']:state(), 'active', 'recovery restores rendering')
  events.textures = 0
  session:update()
  expect.equal(session:draw(), false, 'draw does not veto')
  expect.equal(events.textures, 1, 'the panel draws after recovery')
  session:close()
end)

return test
