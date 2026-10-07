local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local vrUi = require '@testing/vr-ui'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local focus = require '@lunette-contracts/focus'
local display = require '@lunette-contracts/keyboard-display'
local panels = require '@lunette-contracts/panels'
local surfaces = require '@lunette-contracts/surfaces'

local test = testing.suite()
local name = 'example/ui/form'
local actionId = 'example/ui/open'

local function description(service)
  for _, panel in service:panels() do
    local current = panel:describe()
    if current.name == name then
      return current, panel
    end
  end
  return nil
end

local function control(service, id)
  for _, current in assert(description(service)).controls do
    if current.id == id then
      return current
    end
  end
  error('missing example control ' .. id)
end

local function item(service, id, itemId)
  for _, current in control(service, id).items do
    if current.id == itemId then
      return current
    end
  end
  return nil
end

local function action(service)
  for _, current in service:list() do
    if current.id == actionId then
      return current
    end
  end
  error 'missing example open action'
end

local function boot(provider)
  testing.host.useConfiguration 'examples/ui'
  local patches = { { insert = { id = name, definition = require 'form' } } }
  if provider == 'substitute' then
    patches[#patches + 1] = { id = 'ui', definition = require('@testing/ui-substitute').definition }
  end
  local fixture = vrUi.boot(desktop.compose { patches = patches })
  local session = fixture.session
  local env = {
    fixture = fixture,
    session = session,
    native = fixture.native,
    ui = session:observe(ui.capability).service,
    menu = session:observe(menu.capability).service,
    focus = session:observe(focus.capability).service,
    display = session:observe(display.capability).service,
    panels = session:observe(panels.capability).service,
    surfaces = session:observe(surfaces.capability).service,
  }
  fixture:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
  fixture:tracked('left', true)
  fixture:step()
  return env
end

local function withEnvironment(provider, run)
  local env = boot(provider)
  local ok, problem = pcall(run, env)
  local closed, failure = pcall(env.fixture.close, env.fixture)
  if not ok then
    error(tostring(problem) .. (if closed then '' else '; cleanup: ' .. tostring(failure)), 0)
  end
  if not closed then
    error(failure, 0)
  end
end

local function click(env, id, itemId, hand)
  env.fixture:clickControl(env.ui, name, id, hand or 'right', itemId)
end

local function open(env)
  env.fixture:clickControl(env.ui, 'desktop/menu', 'open')
  env.fixture:clickControl(env.ui, 'desktop/menu', 'actions', 'right', actionId)
  env.fixture:clickControl(env.ui, 'desktop/menu', 'close')
end

local function key(env, code)
  local board
  for _, candidate in env.surfaces:all() do
    if candidate.keys and candidate.setVisible then
      assert(board == nil, 'one shared keyboard is offered')
      board = candidate
    end
  end
  assert(board and board.visible, 'the shared keyboard is visible')
  board:setPose(lovr.math.newMat4():translate(0, 0.6, -0.8))
  for _, current in board:keys() do
    if current.code == code then
      env.fixture:click({
        pose = board.pose,
        width = board.width,
        height = board.height,
        logicalWidth = board.width,
        logicalHeight = board.height,
        visible = board.visible,
      }, current.x + current.width / 2, current.y + current.height / 2, 'left')
      return
    end
  end
  error('missing shared keyboard code ' .. tostring(code))
end

local function status(env)
  env.native.events.draw = {}
  env.fixture:draw()
  for _, call in env.fixture:drawCalls 'text' do
    if type(call[2]) == 'string' and call[2]:find('Presses:', 1, true) then
      return call[2]
    end
  end
  error 'the custom region does not draw its status'
end

local function scrollTo(env, id, itemId)
  for _ = 1, 80 do
    local target = item(env.ui, id, itemId)
    if target and target.bounds then
      return
    end
    local current, widget = env.fixture:discover(env.ui, name, id)
    local bounds = assert(widget.bounds)
    env.fixture:aim(current, bounds.x + bounds.width / 2, bounds.y + bounds.height - 8)
    env.fixture:axis('right', 0, -1)
    env.fixture:step()
    env.fixture:axis('right', 0, 0)
    env.fixture:step()
  end
  error('the controller cannot scroll to ' .. itemId)
end

local function captureRegion(env)
  local current, region = env.fixture:discover(env.ui, name, 'preview')
  local bounds = assert(region.bounds)
  env.fixture:aim(current, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 'left')
  env.fixture:step()
  env.fixture:button('left', 'trigger', true)
  env.fixture:step()
end

local function application(env)
  local window = env.native.newWindow(81, 'example-application')
  env.native.events.windows = { window }
  env.native.emit('onWindowOpened', { window = window })
  local panel = assert(env.panels:forSource(window))
  panel:setPose(lovr.math.newMat4():translate(2, 1.2, -1))
  local current = {
    pose = panel.pose,
    width = panel.width,
    height = panel.height,
    logicalWidth = panel.width,
    logicalHeight = panel.height,
    visible = not panel.hidden,
  }
  env.fixture:click(current, current.width / 2, current.height / 2)
  local focused = false
  for _, seat in env.native.events.seats do
    focused = focused or seat.focus == window.sink
  end
  expect.truthy(focused, 'the real desktop application panel acquires native seat focus')
  return window
end

test('the UI configuration boots and draws through the shipped desktop', function()
  local native = testing.native()
  testing.host.useConfiguration 'examples/ui'
  require 'main'
  lovr.load()
  lovr.update(0.016)
  expect.equal(lovr.draw(native.events.pass), false, 'the example does not veto drawing')
  expect.equal(lovr.quit(), false, 'the example does not veto normal quit')
  native.assertResourcesReleased()
end)

for _, provider in { 'built-in', 'substitute' } do
  test(provider .. ' third-party form completes its controller-only workflow and moves with a grip', function()
    withEnvironment(provider, function(env)
      local initial = assert(description(env.ui))
      expect.falsy(initial.visible, 'the form starts hidden')
      expect.equal(action(env.menu).id, actionId, 'the stable wrist action id')
      open(env)
      expect.truthy(assert(description(env.ui)).visible, 'the wrist action opens the form')
      for _, id in { 'press', 'name', 'mode', 'destinations', 'preview', 'close' } do
        expect.truthy(control(env.ui, id).bounds, 'public geometry describes ' .. id)
      end
      click(env, 'press')
      expect.truthy(status(env):find('Presses: 1', 1, true), 'the button invokes the consumer callback')
      click(env, 'name')
      expect.truthy(env.focus:focused(), 'the field has a local focus route')
      expect.truthy(env.display:isVisible(), 'the field requests the shared keyboard')
      expect.equal(env.fixture:keyboardCount(), 1, 'the field creates only one shared keyboard')
      key(env, 16)
      expect.truthy(status(env):find('name: q', 1, true), 'a VR key edits the form text')
      click(env, 'mode')
      click(env, 'mode', 'studio')
      expect.truthy(status(env):find('mode: studio', 1, true), 'the choice invokes the consumer callback')
      click(env, 'mode')
      expect.truthy(assert(item(env.ui, 'mode', 'studio')).selected, 'the reopened choice exposes its selection')
      click(env, 'mode', 'studio')
      expect.equal(item(env.ui, 'destinations', 'destination-24'), nil, 'the long list requires scrolling')
      scrollTo(env, 'destinations', 'destination-24')
      click(env, 'destinations', 'destination-24')
      expect.truthy(
        assert(item(env.ui, 'destinations', 'destination-24')).selected,
        'controller scrolling reaches the last row'
      )
      expect.truthy(status(env):find('destination: destination-24', 1, true), 'the list invokes the consumer callback')
      click(env, 'preview')
      expect.truthy(status(env):find('taps: 1', 1, true), 'the custom region receives a real pointer gesture')

      local before = assert(description(env.ui))
      env.fixture:aim(before, 300, 12)
      env.fixture:step()
      env.fixture:button('right', 'grip', true)
      env.fixture:step()
      local state = env.native.events.controllers.right
      env.fixture:pose('right', lovr.math.newMat4(state.pose):translate(0.2, 0, 0))
      env.fixture:step()
      env.fixture:button('right', 'grip', false)
      env.fixture:step()
      local moved = assert(description(env.ui))
      expect.near(moved.pose[13], before.pose[13] + 0.2, 1e-5, 'the plugin-owned form is movable')
      click(env, 'press')
      expect.truthy(status(env):find('Presses: 2', 1, true), 'fresh public geometry reaches the moved form')
      expect.equal(env.fixture:keyboardCount(), 1, 'the whole workflow retains one shared keyboard')
    end)
  end)

  test(provider .. ' Close cancels the edited field and captured region before the wrist action reopens', function()
    withEnvironment(provider, function(env)
      open(env)
      local initial = assert(description(env.ui))
      click(env, 'name')
      key(env, 16)
      captureRegion(env)
      click(env, 'close')
      expect.falsy(assert(description(env.ui)).visible, 'Close hides the form while editing')
      expect.equal(env.focus:focused(), nil, 'Close releases the local keyboard route')
      expect.falsy(env.display:isVisible(), 'Close ends the automatic keyboard claim')
      env.fixture:button('left', 'trigger', false)
      env.fixture:step()
      env.fixture:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
      open(env)
      expect.equal(assert(description(env.ui)).generation, initial.generation, 'reopening reuses the panel')
      expect.equal(env.focus:focused(), nil, 'reopening does not resurrect the edited route')
      expect.truthy(status(env):find('cancelled: 1', 1, true), 'hiding cancels the custom capture exactly once')
      expect.truthy(status(env):find('taps: 0', 1, true), 'the cancelled gesture does not activate the region')
      click(env, 'name')
      expect.equal(env.fixture:keyboardCount(), 1, 'editing again reuses the shared keyboard')
      key(env, 16)
      expect.truthy(status(env):find('name: qq', 1, true), 'ordinary hiding retains committed text')
    end)
  end)

  test(provider .. ' removing the form during editing releases its panel, menu action, focus, and captures', function()
    withEnvironment(provider, function(env)
      open(env)
      click(env, 'name')
      key(env, 16)
      local savedAction = action(env.menu)
      local _, oldPanel = description(env.ui)
      captureRegion(env)
      env.session.instances[name]:dispose()
      expect.truthy(oldPanel.dead, 'unloading releases the plugin-owned panel')
      expect.equal(description(env.ui), nil, 'the removed panel is not discoverable')
      expect.equal(env.focus:focused(), nil, 'unloading clears the edited route')
      expect.falsy(env.display:isVisible(), 'unloading clears the keyboard claim')
      expect.equal(env.menu:invoke(actionId, savedAction.registration).kind, 'unavailable', 'the ended action is inert')
      env.fixture:button('left', 'trigger', false)
      env.fixture:step()
      application(env)
      env.session:use(require 'form')
      expect.falsy(assert(description(env.ui)).visible, 'a new activation starts hidden')
      expect.equal(
        env.menu:invoke(actionId, savedAction.registration).kind,
        'unavailable',
        'stale rows cannot open replacements'
      )
    end)
  end)

  test(provider .. ' editing hands keyboard focus to a real desktop application without leaking form text', function()
    withEnvironment(provider, function(env)
      open(env)
      click(env, 'name')
      key(env, 16)
      local edited = env.focus:focused()
      application(env)
      expect.truthy(env.focus:focused() ~= edited, 'the application supersedes the local field route')
      env.fixture:clickControl(env.ui, 'desktop/menu', 'open')
      env.fixture:clickControl(env.ui, 'desktop/menu', 'actions', 'right', 'desktop/keyboard/toggle')
      env.fixture:clickControl(env.ui, 'desktop/menu', 'close')
      expect.truthy(env.display:isVisible(), 'the wrist menu reopens the application keyboard')
      env.native.events.input = {}
      key(env, 16)
      local delivered = env.fixture:nativeCalls 'key'
      expect.equal(#delivered, 2, 'the shared VR keyboard delivers a native key press and release')
      expect.equal(delivered[1][2], 16, 'the application receives the selected evdev key')
      expect.equal(delivered[1][3], true, 'the application receives the key press')
      expect.equal(delivered[2][3], false, 'the application receives the key release')
      expect.truthy(status(env):find('name: q;', 1, true), 'the application key does not edit the form')
      click(env, 'close')
      expect.truthy(env.focus:focused(), 'closing the unfocused form preserves the application route')
    end)
  end)
end

return test
